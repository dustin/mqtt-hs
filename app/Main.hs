{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Concurrent       (threadDelay)
import           Control.Concurrent.Async (async, cancel)
import           Control.Monad            (forever)

import           Network.MQTT.Client

main :: IO ()
main = do
  mc <- runClient mqttConfig{_hostname="localhost", _service="1883", _connID="hasqttl",
                             -- _cleanSession=False,
                             _lwt=Just $ mkLWT "tmp/haskquit" "bye for now" False,
                             _msgCB=Just showme}
  print =<< subscribe mc [("oro/#", QoS0), ("tmp/#", QoS2)]
  p <- async $ forever $ publish mc "tmp/mqtths" "hi from haskell" False >> threadDelay 10000000

  putStrLn "Publishing at QoS > 0"
  publishq mc "tmp/q" "this message is at QoS 2" False QoS2
  putStrLn "Published!"

  print =<< waitForClient mc
  cancel p

    where showme t m = print (t,m)
