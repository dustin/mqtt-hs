{-# LANGUAGE OverloadedStrings #-}

module Example2 where

import Network.MQTT.Client
import Network.URI (parseURI)

main :: IO ()
main = do
  let (Just uri) = parseURI "mqtt://test.mosquitto.org"
  mc <- connectURI mqttConfig{_msgCB=SimpleCallback msgReceived} uri
  print =<< subscribe mc [("tmp/topic1", subOptions), ("tmp/topic2", subOptions)] []
  waitForClient mc   -- wait for the the client to disconnect

  where
    msgReceived _ t m p = print (t,m,p)
