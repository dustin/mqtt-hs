{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Concurrent       (threadDelay)
import           Control.Concurrent.Async (async, cancel, wait)
import           Control.Monad            (forever)

import           Network.MQTT.Client

main :: IO ()
main = do
  mc <- runClient mqttConfig{_hostname="localhost", _service="1883", _connID="hasqttl",
                             _lwt=Just $ mkLWT "tmp/haskquit" "bye for now" False,
                             _msgCB=Just showme}
  subscribe mc [("oro/#", 0), ("tmp/#", 0)]
  async $ forever $ publish mc "tmp/mqtths" "hi from haskell" False >> threadDelay 10000000

  waitForClient mc
  putStrLn "Won't get this far without a catch"

    where showme t m = print (t,m)
