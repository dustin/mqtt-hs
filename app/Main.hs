{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Concurrent       (threadDelay)
import           Control.Concurrent.Async (async, cancel)
import           Control.Monad            (forever)

import           Network.MQTT.Client

main :: IO ()
main = do
  mc <- runClient mqttConfig{_hostname="test.mosquitto.org", _port=1883, _connID="hasq",
                             -- _cleanSession=False,
                             _lwt=Just $ (mkLWT "tmp/haskquit" "bye for now" False){
                                _willProps=Properties [PropUserProperty "lwt" "prop"]},
                             _msgCB=Just showme, _protLvl=Protocol50,
                             _connProps=Properties [PropReceiveMaximum 65535,
                                                    PropTopicAliasMaximum 10,
                                                    PropRequestResponseInformation 1,
                                                    PropRequestProblemInformation 1]}
  putStrLn "connected!"
  print =<< svrProps mc
  print =<< subscribe mc [("oro/#", defaultSubOptions), ("tmp/#", defaultSubOptions{_subQoS=QoS2})]

  p <- async $ forever $ pubAliased mc "tmp/hi/from/haskell" "hi from haskell" False QoS1 mempty >> threadDelay 10000000

  putStrLn "Publishing at QoS > 0"
  publishq mc "tmp/q" "this message is at QoS 2" True QoS2 (Properties [
                                                               PropUserProperty "hi" "there",
                                                               PropMessageExpiryInterval 30,
                                                               PropContentType "text/plain"])
  putStrLn "Published!"

  print =<< waitForClient mc
  cancel p

    where showme _ t m = print (t,m)
