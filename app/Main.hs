{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Concurrent       (threadDelay)
import           Control.Concurrent.Async (async, cancel)
import           Control.Monad            (forever, when)
import           Data.Either              (fromLeft, isLeft)

import           Network.MQTT.Client

main :: IO ()
main = do
  emc <- runClient mqttConfig{_hostname="localhost", _service="1883", _connID="hasqttl",
                              _lwt=Just $ mkLWT "tmp/haskquit" "bye for now" False,
                              _msgCB=Just showme}
  when (isLeft emc) $ fail (fromLeft "unknown" emc)

  let (Right mc) = emc
  print =<< subscribe mc [("oro/#", 0), ("tmp/#", 0)]
  p <- async $ forever $ publish mc "tmp/mqtths" "hi from haskell" False >> threadDelay 10000000

  print =<< waitForClient mc
  cancel p

    where showme t m = print (t,m)
