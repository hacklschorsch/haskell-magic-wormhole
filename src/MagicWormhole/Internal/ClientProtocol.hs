-- | The peer-to-peer aspects of the Magic Wormhole protocol.
--
-- Described as the "client" protocol in the Magic Wormhole documentation.
module MagicWormhole.Internal.ClientProtocol
  ( pakeExchange
  , versionExchange
  , Error
  -- * Exported for testing
  , wormholeSpakeProtocol
  , decrypt
  , encrypt
  , deriveKey
  , SessionKey(..) -- XXX: Figure out how to avoid exporting the constructors.
  , Versions(..)
  , phasePurpose
  , spakeBytesToMessageBody
  , messageBodyToSpakeBytes
  ) where

import Protolude hiding (phase)

import Control.Monad (fail)
import Crypto.Hash (SHA256(..), hashWith)
import qualified Crypto.KDF.HKDF as HKDF
import qualified Crypto.Saltine.Internal.ByteSizes as ByteSizes
import qualified Crypto.Saltine.Class as Saltine
import qualified Crypto.Saltine.Core.SecretBox as SecretBox
import qualified Crypto.Spake2 as Spake2
import Crypto.Spake2.Group (Group(arbitraryElement))
import Crypto.Spake2.Groups (Ed25519(..))
import Data.Aeson (FromJSON, ToJSON, (.=), object, Value(..), (.:))
import Data.Aeson.Types (typeMismatch)
import qualified Data.Aeson as Aeson
import qualified Data.ByteArray as ByteArray
import Data.ByteArray.Encoding (convertToBase, convertFromBase, Base(Base16))
import qualified Data.ByteString as ByteString
import Data.String (String)

import qualified MagicWormhole.Internal.Messages as Messages
import qualified MagicWormhole.Internal.Peer as Peer


-- | The version of the SPAKE2 protocol used by Magic Wormhole.
type Spake2Protocol = Spake2.Protocol Ed25519 SHA256

newtype Spake2Message = Spake2Message { spake2Bytes :: ByteString } deriving (Eq, Show)

instance ToJSON Spake2Message where
  toJSON (Spake2Message msg) = object [ "pake_v1" .= toS @ByteString @Text (convertToBase Base16 msg) ]

instance FromJSON Spake2Message where
  parseJSON (Object msg) = do
    hexKey <- toS @Text @ByteString <$> msg .: "pake_v1"
    case convertFromBase Base16 hexKey of
      Left err -> fail err
      Right key -> pure $ Spake2Message key
  parseJSON unknown = typeMismatch "Spake2Message" unknown

spakeBytesToMessageBody :: ByteString -> Messages.Body
spakeBytesToMessageBody = Messages.Body . toS . Aeson.encode . Spake2Message

messageBodyToSpakeBytes :: Messages.Body -> Either Text ByteString
messageBodyToSpakeBytes (Messages.Body bodyBytes) =
  bimap toS spake2Bytes . Aeson.eitherDecode . toS $ bodyBytes

-- | Construct a SPAKE2 protocol compatible with Magic Wormhole.
wormholeSpakeProtocol :: Messages.AppID -> Spake2Protocol
wormholeSpakeProtocol (Messages.AppID appID') =
  Spake2.makeSymmetricProtocol SHA256 Ed25519 blind sideID
  where
    blind = arbitraryElement Ed25519 ("symmetric" :: ByteString)
    sideID = Spake2.SideID (toS appID')


-- XXX: Lots of duplicated code sending JSON data. Either make a typeclass for
-- this sort of thing or at least sendJSON, receiveJSON.

-- TODO: I've been playing fast and loose with Text -> ByteString conversions
-- (grep for `toS`) for the details. The Python implementation occasionally
-- encodes as `ascii` rather than the expected `UTF-8`, so I need to be a bit
-- more careful.

-- | SPAKE2 key used for the duration of a Magic Wormhole peer-to-peer connection.
--
-- Individual messages will be encrypted using 'encrypt' ('decrypt'), which
-- must be given a key that's /generated/ from this one (see 'deriveKey' and
-- 'derivePhaseKey').
newtype SessionKey = SessionKey ByteString

-- | Exchange SPAKE2 keys with a Magic Wormhole peer.
pakeExchange :: Peer.Connection -> Spake2.Password -> IO (Either Error SessionKey)
pakeExchange connection password = do
  let protocol = wormholeSpakeProtocol (Peer.appID connection)
  bimap ProtocolError SessionKey <$> Spake2.spake2Exchange protocol password sendPakeMessage (atomically receivePakeMessage)
  where
    sendPakeMessage = Peer.send connection Messages.PakePhase . spakeBytesToMessageBody
    receivePakeMessage  = do
      -- XXX: This is kind of a fun approach, but it means that everyone else
      -- has to promise that they *don't* consume pake messages.
      msg <- Peer.receive connection
      unless (Messages.phase msg == Messages.PakePhase) retry
      pure $ messageBodyToSpakeBytes (Messages.body msg)

-- | Exchange version information with a Magic Wormhole peer.
--
-- Obtain the 'SessionKey' from 'pakeExchange'.
versionExchange :: Peer.Connection -> SessionKey -> IO (Either Error Versions)
versionExchange connection key = do
  (_, theirVersions) <- concurrently sendVersion receiveVersion
  pure $ case theirVersions of
    Left err -> Left err
    Right theirs
      | theirs /= Versions -> Left VersionMismatch
      | otherwise -> Right Versions
  where
    sendVersion = sendEncrypted connection key Messages.VersionPhase (toS (Aeson.encode Versions))
    receiveVersion = runExceptT $ do
      plaintext <- ExceptT $ receiveEncrypted connection key
      ExceptT $ pure $ first ParseError (Aeson.eitherDecode (toS plaintext))

-- NOTE: Versions
-- ~~~~~~~~~~~~~~
--
-- Magic Wormhole Python implementation sends the following as the 'version' phase:
--     {"app_versions": {}}
--
-- The idea is that /some time in the future/ this will be used to indicate
-- capabilities of peers. At present, it is unused, save as a confirmation
-- that the SPAKE2 exchange worked.

data Versions = Versions deriving (Eq, Show)

instance ToJSON Versions where
  toJSON _ = object ["app_versions" .= object []]

instance FromJSON Versions where
  parseJSON (Object v) = do
    -- Make sure there's an object in the "app_versions" key and abort if not.
    (Object _versions) <- v .: "app_versions"
    pure Versions
  parseJSON unknown = typeMismatch "Versions" unknown


sendEncrypted :: Peer.Connection -> SessionKey -> Messages.Phase -> PlainText -> IO ()
sendEncrypted connection key phase plaintext = do
  ciphertext <- encrypt derivedKey plaintext
  Peer.send connection phase (Messages.Body ciphertext)
  where
    derivedKey = deriveKey key (phasePurpose (Peer.ourSide connection) phase)

receiveEncrypted :: Peer.Connection -> SessionKey -> IO (Either Error PlainText)
receiveEncrypted connection key = do
  message <- atomically $ Peer.receive connection
  let Messages.Body ciphertext = Messages.body message
  pure $ decrypt (derivedKey message) ciphertext
  where
    derivedKey msg = deriveKey key (phasePurpose (Messages.side msg) (Messages.phase msg))


-- | The purpose of a message. 'deriveKey' combines this with the 'SessionKey'
-- to make a unique 'SecretBox.Key'. Do not re-use a 'Purpose' to send more
-- than one message.
type Purpose = ByteString

-- | Derive a one-off key from the SPAKE2 'SessionKey'. Use this key only once.
deriveKey :: SessionKey -> Purpose -> SecretBox.Key
deriveKey (SessionKey key) purpose =
  fromMaybe (panic "Could not encode to SecretBox key") $ -- Impossible. We guarantee it's the right size.
    Saltine.decode (HKDF.expand (HKDF.extract salt key :: HKDF.PRK SHA256) purpose keySize)
  where
    salt = "" :: ByteString
    keySize = ByteSizes.secretBoxKey

-- | Obtain a 'Purpose' for deriving a key to send a message that's part of a
-- peer-to-peer communication.
phasePurpose :: Messages.Side -> Messages.Phase -> Purpose
phasePurpose (Messages.Side side) phase = "wormhole:phase:" <> sideHashDigest <> phaseHashDigest
  where
    sideHashDigest = hashDigest (toS @Text @ByteString side)
    phaseHashDigest = hashDigest (toS (Messages.phaseName phase) :: ByteString)
    hashDigest thing = ByteArray.convert (hashWith SHA256 thing)

-- XXX: Different types for ciphertext and plaintext please!
type CipherText = ByteString
type PlainText = ByteString

-- | Encrypt a message using 'SecretBox'. Get the key from 'deriveKey'.
-- Decrypt with 'decrypt'.
encrypt :: SecretBox.Key -> PlainText -> IO CipherText
encrypt key message = do
  nonce <- SecretBox.newNonce
  let ciphertext = SecretBox.secretbox key nonce message
  pure $ Saltine.encode nonce <> ciphertext

-- | Decrypt a message using 'SecretBox'. Get the key from 'deriveKey'.
-- Encrypted using 'encrypt'.
decrypt :: SecretBox.Key -> CipherText -> Either Error PlainText
decrypt key ciphertext = do
  let (nonce', ciphertext') = ByteString.splitAt ByteSizes.secretBoxNonce ciphertext
  nonce <- note (InvalidNonce nonce') $ Saltine.decode nonce'
  note (CouldNotDecrypt ciphertext') $ SecretBox.secretboxOpen key nonce ciphertext'


data Error
  = ParseError String
  | ProtocolError (Spake2.MessageError Text)
  | CouldNotDecrypt ByteString
  | VersionMismatch
  | InvalidNonce ByteString
  deriving (Eq, Show)