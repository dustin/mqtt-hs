{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Network.MQTT.Client where

import           Control.Concurrent              (forkIO, threadDelay)
import           Control.Concurrent.STM          (TChan, TVar, atomically,
                                                  modifyTVar', newTChanIO,
                                                  newTVarIO, readTChan,
                                                  readTVar, writeTChan)
import           Control.Monad                   (forever)
import qualified Data.Attoparsec.ByteString.Lazy as A
import qualified Data.ByteString.Lazy            as BL
import qualified Data.ByteString.Lazy.Char8      as BC
import           Data.Default                    (Default (..))
import           Data.Text                       (Text)
import qualified Data.Text.Encoding              as TE
import           Data.Word                       (Word16)
import           Network.Socket                  (Socket, SocketType (..),
                                                  addrAddress, addrFamily,
                                                  addrProtocol, addrSocketType,
                                                  connect, defaultHints,
                                                  getAddrInfo, socket)
import           Network.Socket.ByteString.Lazy  (getContents, sendAll)
import           Prelude                         hiding (getContents)

import           Network.MQTT.Types              as T


data MQTTClient = MQTTClient {
  _out     :: BL.ByteString -> IO ()
  , _in    :: BL.ByteString
  , _ch    :: TChan MQTTPkt
  , _cb    :: Maybe (Text -> BL.ByteString -> IO ())
  , _pktID :: TVar Word16
  }

data MQTTClientConfig = MQTTClientConfig {
  _hostname       :: String
  , _service      :: String
  , _connID       :: String
  , _username     :: Maybe String
  , _password     :: Maybe String
  , _cleanSession :: Bool
  , _lwt          :: Maybe LastWill
  , _msgCB        :: Maybe (Text -> BL.ByteString -> IO ())
  }

instance Default MQTTClientConfig where
  def = MQTTClientConfig{_hostname="", _service="", _connID="",
                         _username=Nothing, _password=Nothing,
                         _cleanSession=True, _lwt=Nothing,
                         _msgCB=Nothing}

connectTo :: MQTTClientConfig -> IO MQTTClient
connectTo MQTTClientConfig{..} = do
  addr <- resolve _hostname _service
  -- TODO:  Figure out good bracketing for this
  sock <- open addr
  fromSocket sock >>= \c -> startClient c{_cb=_msgCB} def{T._connID=BC.pack _connID,
                                                          T._lastWill=_lwt,
                                                          T._username=BC.pack <$> _username,
                                                          T._password=BC.pack <$> _password,
                                                          T._cleanSession=_cleanSession}

  where
    resolve host port = do
        let hints = defaultHints { addrSocketType = Stream }
        addr:_ <- getAddrInfo (Just hints) (Just host) (Just port)
        pure addr
    open addr = do
        sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
        connect sock $ addrAddress addr
        pure sock

fromSocket :: Socket -> IO MQTTClient
fromSocket s = do
  let _out = sendAll s
  _in <- getContents s
  _ch <- newTChanIO
  _pktID <- newTVarIO 0
  let _cb = Nothing
  pure MQTTClient{..}

capture :: MQTTClient -> IO ()
capture c@MQTTClient{..} = do
  let (A.Done s' res) = A.parse parsePacket _in
  case res of
    (PublishPkt PublishRequest{..}) -> case _cb of
                                         Nothing -> pure ()
                                         Just x -> x (blToText _pubTopic) _pubBody
    x -> print x
  capture c{_in=s'}

startClient :: MQTTClient -> ConnectRequest -> IO MQTTClient
startClient c@MQTTClient{..} r = do
  _out (toByteString r)
  let (A.Done in' res) = A.parse parsePacket _in
  let (ConnACKPkt (ConnACKFlags _ val)) = res
  case val of
    0 -> pure ()
    1 -> fail "unacceptable protocol version"
    2 -> fail "identifier rejected"
    3 -> fail "server unavailable"
    4 -> fail "bad username or password"
    5 -> fail "not authorized"

  let c' = c{_in=in'}
  _ <- forkIO $ forever mqttWriter
  _ <- forkIO $ capture c'
  _ <- forkIO $ forever $ sendPacket c PingPkt >> threadDelay 6000000
  pure c'

  where
    mqttWriter = (atomically . readTChan) _ch >>= _out . toByteString


sendPacket :: MQTTClient -> MQTTPkt -> IO ()
sendPacket MQTTClient{..} = atomically . writeTChan _ch

textToBL :: Text -> BL.ByteString
textToBL = BL.fromStrict . TE.encodeUtf8

blToText :: BL.ByteString -> Text
blToText = TE.decodeUtf8 . BL.toStrict

subscribe :: MQTTClient -> [(Text, Int)] -> IO ()
subscribe MQTTClient{..} ls = atomically $ do
  pid <- readTVar _pktID
  modifyTVar' _pktID succ
  writeTChan _ch (SubscribePkt $ SubscribeRequest pid ls')

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
