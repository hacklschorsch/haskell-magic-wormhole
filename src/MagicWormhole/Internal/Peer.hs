-- | The peer-to-peer aspects of the Magic Wormhole protocol.
--
-- Described as the "client" protocol in the Magic Wormhole documentation.
module MagicWormhole.Internal.Peer
  ( pakeExchange
  , Error
  -- * Exported for testing
  , wormholeSpakeProtocol
  , decodeElement
  , encodeElement
  , decrypt
  , encrypt
  , derivePhaseKey
  ) where

import Protolude hiding (phase)

import Control.Monad (fail)
import Crypto.Hash (SHA256(..), hashWith)
import qualified Crypto.KDF.HKDF as HKDF
import qualified Crypto.Saltine.Internal.ByteSizes as ByteSizes
import qualified Crypto.Saltine.Class as Saltine
import qualified Crypto.Saltine.Core.SecretBox as SecretBox
import qualified Crypto.Spake2 as Spake2
import Crypto.Spake2.Group (Group(Element, arbitraryElement))
import Crypto.Spake2.Groups (Ed25519(..))
import Data.Aeson (FromJSON, ToJSON, (.=), object, Value(..), (.:))
import Data.Aeson.Types (typeMismatch)
import qualified Data.Aeson as Aeson
import qualified Data.ByteArray as ByteArray
import Data.ByteArray.Encoding (convertToBase, convertFromBase, Base(Base16))
import qualified Data.ByteString as ByteString
import Data.String (String)

import qualified MagicWormhole.Internal.Messages as Messages
import qualified MagicWormhole.Internal.Rendezvous as Rendezvous

-- | The version of the SPAKE2 protocol used by Magic Wormhole.
type Spake2Protocol = Spake2.Protocol Ed25519 SHA256

newtype Spake2Message = Spake2Message ByteString deriving (Eq, Show)

instance ToJSON Spake2Message where
  toJSON (Spake2Message msg) = object [ "pake_v1" .= toS @ByteString @Text (convertToBase Base16 msg) ]

instance FromJSON Spake2Message where
  parseJSON (Object msg) = do
    hexKey <- toS @Text @ByteString <$> msg .: "pake_v1"
    case convertFromBase Base16 hexKey of
      Left err -> fail err
      Right key -> pure $ Spake2Message key
  parseJSON unknown = typeMismatch "Spake2Message" unknown

type Spake2Element = Element Ed25519

decodeElement :: Spake2Protocol -> Messages.Body -> Either Error Spake2Element
decodeElement protocol (Messages.Body body) = do
  Spake2Message msg <- first ParseError (Aeson.eitherDecode (toS body))
  first ProtocolError $ Spake2.extractElement protocol msg

encodeElement :: Spake2Protocol -> Spake2Element -> Messages.Body
encodeElement protocol = Messages.Body . toS . Aeson.encode . Spake2Message . Spake2.elementToMessage protocol

-- | Construct a SPAKE2 protocol compatible with Magic Wormhole.
wormholeSpakeProtocol :: Messages.AppID -> Spake2Protocol
wormholeSpakeProtocol (Messages.AppID appID) =
  Spake2.makeSymmetricProtocol SHA256 Ed25519 blind sideID
  where
    blind = arbitraryElement Ed25519 ("S" :: ByteString)
    sideID = Spake2.SideID (toS appID)


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
pakeExchange :: Rendezvous.Session -> Spake2.Password -> IO (Either Error SessionKey)
pakeExchange session password = do
  let protocol = wormholeSpakeProtocol (Rendezvous.sessionAppID session)
  exchange <- Spake2.startSpake2 protocol password
  let outbound = Spake2.computeOutboundMessage exchange
  (_, inbound) <- concurrently (sendPakeMessage protocol outbound) (atomically (receivePakeMessage protocol))
  case inbound of
    Left err -> pure (Left err)  -- Could not parse the SPAKE2 message
    Right inbound' ->
      let
        keyMaterial = Spake2.generateKeyMaterial exchange inbound'
        sessionKey = Spake2.createSessionKey protocol inbound' outbound keyMaterial password
      in pure . Right . SessionKey $ sessionKey
  where
    sendPakeMessage protocol outbound =
      let body = encodeElement protocol outbound
      in Rendezvous.add session Messages.PakePhase body

    receivePakeMessage protocol = do
      -- XXX: This is kind of a fun approach, but it means that everyone else
      -- has to promise that they *don't* consume pake messages.
      msg <- Rendezvous.readFromMailbox session
      unless (Messages.phase msg == Messages.PakePhase) retry
      pure (decodeElement protocol (Messages.body msg))

{- Straight up translation of some Python code -}

-- | Derive a one-off key from the SPAKE2 'SessionKey'. Use this key only once.
deriveKey :: (ByteArray.ByteArrayAccess info) => SessionKey -> info -> SecretBox.Key
deriveKey (SessionKey key) purpose =
  fromMaybe (panic "Could not encode to SecretBox key") $ -- Impossible. We guarntee it's the right size.
    Saltine.decode (HKDF.expand (HKDF.extract salt key :: HKDF.PRK SHA256) purpose keySize)
  where
    salt = "" :: ByteString
    keySize = ByteSizes.secretBoxKey

derivePhaseKey :: SessionKey -> Messages.Side -> Messages.Phase -> SecretBox.Key
derivePhaseKey key (Messages.Side side) phase =
  deriveKey key purpose
  where
    purpose = "wormhole:phase:" <> sideHashDigest <> phaseHashDigest :: ByteString
    sideHashDigest = hashDigest (toS @Text @ByteString side)
    phaseHashDigest = hashDigest (toS @LByteString @ByteString (Aeson.encode phase))
    hashDigest thing = ByteArray.convert (hashWith SHA256 thing)

-- XXX: Different types for ciphertext and plaintext please!
-- | Encrypt a message using 'SecretBox'. Get the key from 'deriveKey'.
-- Decrypt with 'decrypt'.
encrypt :: SecretBox.Key -> ByteString -> IO ByteString
encrypt key message = do
  nonce <- SecretBox.newNonce
  let ciphertext = SecretBox.secretbox key nonce message
  pure $ Saltine.encode nonce <> ciphertext

-- | Decrypt a message using 'SecretBox'. Get the key from 'deriveKey'.
-- Encrypted using 'encrypt'.
decrypt :: SecretBox.Key -> ByteString -> Maybe ByteString
decrypt key ciphertext = do
  let (nonce', ciphertext') = ByteString.splitAt ByteSizes.secretBoxNonce ciphertext
  nonce <- Saltine.decode nonce'
  SecretBox.secretboxOpen key nonce ciphertext'


data Error
  = ParseError String
  | ProtocolError Spake2.MessageError
  deriving (Eq, Show)