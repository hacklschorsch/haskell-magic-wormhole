module MagicWormhole.Internal.Pake
  ( pakeExchange
  , Error(..)
  -- * Exported for testing
  , spakeBytesToMessageBody
  , messageBodyToSpakeBytes
  ) where

import Protolude

import Control.Monad (fail)
import Crypto.Hash (SHA256(..))
import qualified Crypto.Spake2 as Spake2
import Crypto.Spake2.Group (Group(arbitraryElement))
import Crypto.Spake2.Groups (Ed25519(..))
import qualified Data.Aeson as Aeson
import Data.Aeson (FromJSON, ToJSON, (.=), object, Value(..), (.:))
import Data.Aeson.Types (typeMismatch)
import Data.ByteArray.Encoding (convertToBase, convertFromBase, Base(Base16))

import qualified MagicWormhole.Internal.Messages as Messages
import qualified MagicWormhole.Internal.ClientProtocol as ClientProtocol

-- | Exchange SPAKE2 keys with a Magic Wormhole peer.
--
-- Throws an 'Error' if we cannot parse the incoming message.
pakeExchange :: ClientProtocol.Connection -> Spake2.Password -> IO ClientProtocol.SessionKey
pakeExchange conn password = do
  let protocol = wormholeSpakeProtocol (ClientProtocol.appID conn)
  result <- Spake2.spake2Exchange protocol password sendPakeMessage (atomically receivePakeMessage)
  case result of
    Left err -> throwIO (Error err)
    Right key -> pure (ClientProtocol.SessionKey key)
  where
    sendPakeMessage = ClientProtocol.send conn Messages.PakePhase . spakeBytesToMessageBody
    receivePakeMessage  = do
      -- This is kind of a fun approach, but it means that everyone else has
      -- to promise that they *don't* consume pake messages.
      msg <- ClientProtocol.receive conn
      unless (Messages.phase msg == Messages.PakePhase) retry
      pure $ messageBodyToSpakeBytes (Messages.body msg)


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

-- | The version of the SPAKE2 protocol used by Magic Wormhole.
type Spake2Protocol = Spake2.Protocol Ed25519 SHA256

newtype Error = Error (Spake2.MessageError Text) deriving (Eq, Show, Typeable)
instance Exception Error
