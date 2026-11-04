{-# LANGUAGE OverloadedStrings #-}

module ClientSpec where

import           Control.Concurrent              (threadDelay)
import           Control.Concurrent.Async        (mapConcurrently_)
import           Control.Concurrent.STM          (TVar, atomically, check, modifyTVar', newTVarIO, readTVar)
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
fakeBroker props = do
  written <- newTVarIO []
  let connack = BL.toStrict . toByteString Protocol50 $ ConnACKPkt (ConnACKFlags NewSession ConnAccepted props)
      src = yield connack >> forever (liftIO (threadDelay 1000000))
      sink = awaitForever $ \bs -> liftIO . atomically $ modifyTVar' written (<> [bs])
  pure (written, \f -> f (src, sink))

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
