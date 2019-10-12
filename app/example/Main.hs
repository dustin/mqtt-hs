{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Concurrent       (threadDelay)
import           Control.Concurrent.Async (async, cancel, link)
import           Control.Monad            (forever)
import           Network.URI              (parseURI)

import           Network.MQTT.Client

main :: IO ()
main = do
  let (Just uri) = parseURI "mqtt://test.mosquitto.org"

  mc <- connectURI mqttConfig{_lwt=Just $ (mkLWT "tmp/haskquit" "bye for now" False){
                                _willProps=[PropUserProperty "lwt" "prop"]},
                             _msgCB=SimpleCallback showme, _protocol=Protocol50,
                             _connProps=[PropReceiveMaximum 65535,
                                         PropTopicAliasMaximum 10,
                                         PropRequestResponseInformation 1,
                                         PropRequestProblemInformation 1]}
    uri

  putStrLn "connected!"
  print =<< svrProps mc
  print =<< subscribe mc [("oro/#", subOptions), ("tmp/#", subOptions{_subQoS=QoS2})] mempty

  print =<< unsubscribe mc ["oro/#"] mempty

  let pprops = [PropUserProperty "hello" "mqttv5"]
  p <- async $ forever $ pubAliased mc "tmp/hi/from/haskell" "hi from haskell" False QoS1 pprops >> threadDelay 10000000
  link p

  putStrLn "Publishing at QoS > 0"
  publishq mc "tmp/q1" "this message is at QoS 1" True QoS1 [PropUserProperty "hi" "there 1",
                                                             PropMessageExpiryInterval 30,
                                                             PropContentType "text/plain"]
  putStrLn "Published!"

  putStrLn "Publishing at QoS > 1"
  publishq mc "tmp/q2" "this message is at QoS 2" True QoS2 [PropUserProperty "hi" "there 2",
                                                             PropMessageExpiryInterval 30,
                                                             PropContentType "text/plain"]
  putStrLn "Published!"

  print =<< waitForClient mc
  cancel p

    where showme _ t m p = print (t,m,p)
