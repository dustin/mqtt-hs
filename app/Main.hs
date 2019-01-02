{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Concurrent  (threadDelay)
import           Control.Monad       (forever)
import           Data.Default        (def)

import           Network.MQTT.Client

main :: IO ()
main = do
  mc <- connectTo def{_hostname="localhost", _service="1883", _connID="hasqttl",
                      _lwt=Just $ mkLWT "tmp/haskquit" "bye for now" False,
                      _msgCB=Just showme}
  subscribe mc [("oro/#", 0), ("tmp/#", 0)]
  forever $ publish mc "tmp/mqtths" "hi from haskell" False >> threadDelay 10000000

  where showme t m = print (t,m)
