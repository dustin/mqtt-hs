{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Concurrent              (forkIO, threadDelay)
import           Control.Concurrent.STM          (TChan (..), atomically,
                                                  newTChanIO, readTChan,
                                                  writeTChan)
import           Control.Monad                   (forever)
import qualified Data.Attoparsec.ByteString.Lazy as A
import qualified Data.ByteString.Lazy            as BL
import           Network                         (PortID (..), connectTo)
import           System.IO                       (Handle)

import           Network.MQTT.Types

dump :: BL.ByteString -> IO ()
dump pc = do
  let (A.Done pc' res) = A.parse parsePacket pc
  print res
  dump pc'

publish :: TChan MQTTPkt -> IO ()
publish ch = atomically $ writeTChan ch (PublishPkt $ PublishRequest{
                                            _pubDup = False,
                                            _pubQoS = 0,
                                            _pubPktID = 0,
                                            _pubRetain = False,
                                            _pubTopic = "tmp/mqtths",
                                            _pubBody = "hi from haskell"
                                            })

mqttWriter :: Handle -> TChan MQTTPkt -> IO ()
mqttWriter c ch = do
  p <- atomically $ readTChan ch
  BL.hPut c (toByteString p)
  mqttWriter c ch

pinger :: TChan MQTTPkt -> IO ()
pinger ch = atomically $ writeTChan ch PingPkt

subscribe :: TChan MQTTPkt -> IO ()
subscribe ch = atomically $ writeTChan ch (SubscribePkt $ SubscribeRequest 0 [("oro/#", 0), ("tmp/#", 0)])

main :: IO ()
main = do
  c <- connectTo "eve" (Service "1883")

  let connreq = ConnectRequest{
        _username=Nothing, _password=Nothing, _lastWill=Nothing,
        _cleanSession=True, _keepAlive=900, _connID="mqtths"}
  BL.hPut c (toByteString connreq)

  ch <- newTChanIO
  _ <- forkIO $ mqttWriter c ch
  _ <- forkIO $ dump =<< BL.hGetContents c

  subscribe ch

  forkIO $ forever $ pinger ch >> threadDelay 6000000
  forever $ publish ch >> threadDelay 10000000
