{-# LANGUAGE OverloadedStrings #-}

module Example1 where

import Network.MQTT.Client
import Network.URI (parseURI)

main :: IO ()
main = do
  let (Just uri) = parseURI "mqtt://test.mosquitto.org"
  mc <- connectURI mqttConfig uri
  publish mc "tmp/topic" "hello!" False
