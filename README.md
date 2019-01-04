# mqtt

An [MQTT][mqtt] client for Haskell.

## Example

### Publish

```haskell
main :: IO
main = do
  mc <- runClient mqttConfig{_hostname="localhost", _service="1883", _connID="hasqttl"}
  publish mc "tmp/topic" "hello!" False
```

### Subscribe

```haskell
main :: IO
main = do
  mc <- runClient mqttConfig{_hostname="localhost", _service="1883", _connID="hasqttl",
                             _msgCB=Just msgReceived}
  print =<< subscribe mc [("tmp/topic1", 0), ("tmp/topic2", 0)]
  print =<< waitForClient mc   -- wait for the the client to disconnect

  where
    msgReceived t m = print (t,m)
```

[mqtt]: http://mqtt.org/
