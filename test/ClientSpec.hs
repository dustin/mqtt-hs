{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module ClientSpec where

import           Control.Concurrent              (threadDelay)
import           Control.Concurrent.Async        (mapConcurrently_)
import           Control.Concurrent.Async        (async, poll, wait)
import           Control.Concurrent.STM          (TVar, atomically, check, modifyTVar', newTChanIO, newTVarIO,
                                                  readTChan, readTVar, writeTChan)
import           Control.Monad                   (forM_, forever, replicateM_)
import           Control.Monad.IO.Class          (liftIO)
import qualified Data.Attoparsec.ByteString.Lazy as A
import qualified Data.ByteString                 as BS
import qualified Data.ByteString.Lazy            as BL
import           Data.Conduit                    (awaitForever, yield)
import           System.Timeout                  (timeout)
import           Test.Tasty.HUnit

import           Network.MQTT.Client
import           Network.MQTT.Types              as MT

-- | A fake broker for a client to connect to.  It accepts the connection
-- with the given CONNACK properties and records everything the client
-- writes after the CONNECT.  (The client writes each packet in one
-- chunk.)
fakeBroker :: [MT.Property] -> IO (TVar [BS.ByteString], (MQTTConduit -> IO ()) -> IO ())
fakeBroker props = (\(w, _, c) -> (w, c)) <$> scriptedBroker props

-- | A fake broker that also sends the client whatever packets it's given.
scriptedBroker :: [MT.Property] -> IO (TVar [BS.ByteString], MQTTPkt -> IO (), (MQTTConduit -> IO ()) -> IO ())
scriptedBroker props = do
  written <- newTVarIO []
  inject <- newTChanIO
  let enc = BL.toStrict . toByteString Protocol50
      src = yield (enc $ ConnACKPkt (ConnACKFlags NewSession ConnAccepted props))
            >> forever (liftIO (atomically (readTChan inject)) >>= yield . enc)
      sink = awaitForever $ \bs -> liftIO . atomically $ modifyTVar' written (<> [bs])
  pure (written, atomically . writeTChan inject, \f -> f (src, sink))

-- | Wait for the client to have written the nth packet after its CONNECT.
nthWritten :: Int -> TVar [BS.ByteString] -> IO MQTTPkt
nthWritten n written = do
  got <- timeout 5000000 . atomically $ do
    ws <- drop 1 <$> readTVar written
    check (length ws >= n)
    pure (ws !! (n - 1))
  bs <- maybe (assertFailure ("packet " <> show n <> " never arrived")) pure got
  either (assertFailure . ("unparseable packet: " <>)) pure . A.eitherResult . A.parse (parsePacket Protocol50) $ BL.fromStrict bs

-- | The PUBLISHes a fake broker received, in order, once there are n.
published :: Int -> TVar [BS.ByteString] -> IO [PublishRequest]
published n written = do
  got <- timeout 5000000 . atomically $ do
    ws <- drop 1 <$> readTVar written -- the CONNECT
    check (length ws >= n)
    pure ws
  ws <- maybe (assertFailure "publishes never arrived") pure got
  pure [p | Right (PublishPkt p) <- A.eitherResult . A.parse (parsePacket Protocol50) . BL.fromStrict <$> ws]

-- Concurrent aliased publishes to one topic: the first PUBLISH using the
-- alias has to carry the topic too, or the broker can't know what the
-- alias means [5.0 §3.3.2.3.4].
unit_concurrentAliasedPublishes :: Assertion
unit_concurrentAliasedPublishes = replicateM_ 200 $ do
  (written, conn) <- fakeBroker [PropTopicAliasMaximum 10]
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50}
  mapConcurrently_ (\_ -> pubAliased c "a/b" "x" False QoS0 []) [1 .. 200 :: Int]
  ps <- published 200 written
  forM_ (take 1 ps) $ \p ->
    assertEqual ("first publish names the topic: " <> show p) "a/b" (_pubTopic p)
  stopClient c

-- A QoS 2 publish holds its packet ID until the PUBCOMP, since until then
-- the broker still has the exchange open, and a new PUBLISH reusing the
-- ID would be taken as a duplicate and dropped [MQTT-4.3.3].
unit_qos2HoldsIDUntilPubCOMP :: Assertion
unit_qos2HoldsIDUntilPubCOMP = do
  (written, inject, conn) <- scriptedBroker []
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50}
  p <- async $ publishq c "a/b" "x" False QoS2 []
  PublishPkt PublishRequest{_pubPktID=pid} <- nthWritten 1 written
  inject (PubRECPkt (PubREC pid 0 []))
  nthWritten 2 written >>= assertEqual "PUBREL" (PubRELPkt (PubREL pid 0 []))
  threadDelay 100000
  poll p >>= maybe (pure ()) (const $ assertFailure "publish finished before PUBCOMP")
  inject (PubCOMPPkt (PubCOMP pid 0 []))
  timeout 2000000 (wait p) >>= maybe (assertFailure "publish didn't finish after PUBCOMP") pure
  stopClient c

-- The client pings often enough for a Server Keep Alive shorter than its
-- own ping period [MQTT-3.2.2-21].
unit_honorsServerKeepAlive :: Assertion
unit_honorsServerKeepAlive = do
  (written, _, conn) <- scriptedBroker [PropServerKeepAlive 1]
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50}
  timeout 1500000 (nthWritten 1 written) >>= \case
    Just PingPkt -> pure ()
    x            -> assertFailure ("expected a PINGREQ within 1.5s, got " <> show x)
  stopClient c

-- No more QoS 1 and 2 PUBLISHes are in flight than the server's Receive
-- Maximum [MQTT-3.3.4-7].
unit_honorsReceiveMaximum :: Assertion
unit_honorsReceiveMaximum = do
  (written, inject, conn) <- scriptedBroker [PropReceiveMaximum 1]
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50}
  ps <- mapM (\b -> async $ publishq c "a/b" b False QoS1 []) ["one", "two"]
  PublishPkt PublishRequest{_pubPktID=pid} <- nthWritten 1 written
  threadDelay 200000
  n <- length . drop 1 <$> atomically (readTVar written)
  assertEqual "PUBLISHes in flight before the first ack" 1 n
  inject (PubACKPkt (PubACK pid 0 []))
  PublishPkt PublishRequest{_pubPktID=pid2} <- nthWritten 2 written
  inject (PubACKPkt (PubACK pid2 0 []))
  mapM_ (\p -> timeout 2000000 (wait p) >>= maybe (assertFailure "publish didn't finish") pure) ps
  stopClient c
