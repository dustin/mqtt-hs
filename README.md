# mqtt

An [MQTT][mqtt] protocol implementation for Haskell.

## Client Examples

### Publish

```haskell
main :: IO
main = do
  let (Just uri) = parseURI "mqtt://test.mosquitto.org"
  mc <- connectURI mqttConfig{} uri
  publish mc "tmp/topic" "hello!" False
```

### Subscribe

```haskell
main :: IO
main = do
  let (Just uri) = parseURI "mqtt://test.mosquitto.org"
  mc <- connectURI mqttConfig{_msgCB=Just msgReceived} uri
  print =<< subscribe mc [("tmp/topic1", subOptions), ("tmp/topic2", subOptions)] []
  waitForClient mc   -- wait for the the client to disconnect

  where
    msgReceived _ t m p = print (t,m,p)
```

[mqtt]: http://mqtt.org/
