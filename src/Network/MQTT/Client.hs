{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Network.MQTT.Client where

import           Control.Concurrent              (threadDelay)
import           Control.Concurrent.Async        (async, cancel)
import           Control.Concurrent.STM          (TChan, TVar, atomically,
                                                  modifyTVar', newTChanIO,
                                                  newTVarIO, readTChan,
                                                  readTVar, writeTChan)
import qualified Control.Exception               as E
import           Control.Monad                   (forever)
import qualified Data.Attoparsec.ByteString.Lazy as A
import qualified Data.ByteString.Lazy            as BL
import qualified Data.ByteString.Lazy.Char8      as BC
import           Data.Text                       (Text)
import qualified Data.Text.Encoding              as TE
import           Data.Word                       (Word16)
import           Network.Socket                  (SocketType (..), addrAddress,
                                                  addrFamily, addrProtocol,
                                                  addrSocketType, close,
                                                  connect, defaultHints,
                                                  getAddrInfo, socket)
import           Network.Socket.ByteString.Lazy  (getContents, sendAll)
import           Prelude                         hiding (getContents)

import           Network.MQTT.Types              as T


data MQTTClientInternal = MQTTClientInternal {
  _out     :: BL.ByteString -> IO ()
  , _in    :: BL.ByteString
  , _ch    :: TChan MQTTPkt
  , _pktID :: TVar Word16
  }

data MQTTClient = MQTTClient {
  _hostname       :: String
  , _service      :: String
  , _connID       :: String
  , _username     :: Maybe String
  , _password     :: Maybe String
  , _cleanSession :: Bool
  , _lwt          :: Maybe LastWill
  , _msgCB        :: Maybe (Text -> BL.ByteString -> IO ())
  , _internal     :: MQTTClientInternal
  }

newClient :: IO MQTTClient
newClient = do
  ch <- newTChanIO
  pid <- newTVarIO 0
  pure MQTTClient{_hostname="", _service="", _connID="",
                  _username=Nothing, _password=Nothing,
                  _cleanSession=True, _lwt=Nothing,
                  _msgCB=Nothing,
                  _internal=MQTTClientInternal{
                     _out=undefined,
                     _in=mempty,
                     _ch=ch,
                     _pktID=pid}}

runClient :: MQTTClient -> IO ()
runClient c@MQTTClient{..} = do
  addr <- resolve _hostname _service
  E.bracket (open addr) close $ \s -> E.bracket (start s) cancelAll work

  where
    resolve host port = do
      let hints = defaultHints { addrSocketType = Stream }
      addr:_ <- getAddrInfo (Just hints) (Just host) (Just port)
      pure addr
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect sock $ addrAddress addr
      pure sock
    start s = do
      _in <- getContents s
      let out = sendAll s
          r = connectRequest{T._connID=BC.pack _connID,
                             T._lastWill=_lwt,
                             T._username=BC.pack <$> _username,
                             T._password=BC.pack <$> _password,
                             T._cleanSession=_cleanSession}
      out (toByteString r)
      let (A.Done in' res) = A.parse parsePacket _in
      let (ConnACKPkt (ConnACKFlags _ val)) = res
      case val of
        0 -> pure ()
        1 -> fail "unacceptable protocol version"
        2 -> fail "identifier rejected"
        3 -> fail "server unavailable"
        4 -> fail "bad username or password"
        5 -> fail "not authorized"

      let c' = c{_internal=_internal{_out=out, _in=in'}}
      w <- async $ forever $ (atomically . readTChan) (_ch _internal) >>= out . toByteString
      p <- async $ forever $ sendPacket c' PingPkt >> threadDelay 30000000

      pure (c', [w,p])

    cancelAll = mapM_ cancel . snd

    work = capture . fst

capture :: MQTTClient -> IO ()
capture c@MQTTClient{..} = do
  let (A.Done s' res) = A.parse parsePacket (_in _internal)
  case res of
    (PublishPkt PublishRequest{..}) -> case _msgCB of
                                         Nothing -> pure ()
                                         Just x -> x (blToText _pubTopic) _pubBody
    x -> print x
  capture c{_internal=_internal{_in=s'}}

sendPacket :: MQTTClient -> MQTTPkt -> IO ()
sendPacket MQTTClient{..} = atomically . writeTChan (_ch _internal)

textToBL :: Text -> BL.ByteString
textToBL = BL.fromStrict . TE.encodeUtf8

blToText :: BL.ByteString -> Text
blToText = TE.decodeUtf8 . BL.toStrict

subscribe :: MQTTClient -> [(Text, Int)] -> IO ()
subscribe MQTTClient{..} ls = atomically $ do
  pid <- readTVar (_pktID _internal)
  modifyTVar' (_pktID _internal) succ
  writeTChan (_ch _internal) (SubscribePkt $ SubscribeRequest pid ls')

    where ls' = map (\(s, i) -> (textToBL s, toEnum i)) ls

publish :: MQTTClient -> Text -> BL.ByteString -> Bool -> IO ()
publish c t m r = sendPacket c (PublishPkt $ PublishRequest {
                                   _pubDup = False,
                                   _pubQoS = 0,
                                   _pubPktID = 0,
                                   _pubRetain = r,
                                   _pubTopic = textToBL t,
                                   _pubBody = m})

mkLWT :: Text -> BL.ByteString -> Bool -> T.LastWill
mkLWT t m r = T.LastWill{
  T._willRetain=r,
  T._willQoS=0,
  T._willTopic = textToBL t,
  T._willMsg=m
  }
