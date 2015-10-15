#import "THEMultipeerSocketRelay.h"

@interface THEMultipeerSocketRelay()

// Try to open the socket
- (BOOL)tryCreateSocket;

@end

// Possible states of a relay instance 
typedef enum relayStates {
  INITIALIZED,
  CONNECTED,
  STOPPED 
} RelayState;

@implementation THEMultipeerSocketRelay
{
  // The socket we're using to talk to the upper (localhost) layers
  GCDAsyncSocket *_socket;

  // The input and output stream that we use to talk to the remote peer
  NSInputStream *_inputStream;
  NSOutputStream *_outputStream;

  // Output buffer
  NSMutableArray *_outputBuffer;
  BOOL _outputBufferHasSpaceAvailable;

  // Track our current state
  RelayState _relayState;

  // For debugging purposes only
  NSString *_relayType;
}

- (instancetype)initWithRelayType:(NSString *)relayType
{
  if (self = [super init]) 
  { 
    _relayType = relayType;
    _relayState = INITIALIZED;
  }

  _outputBuffer = [[NSMutableArray alloc] init];  
  _outputBufferHasSpaceAvailable = NO;

  return self;
}

- (void)setInputStream:(NSInputStream *)inputStream
{
  // inputStream is from the multipeer session, data from the remote
  // peer will appear here
  assert(inputStream && _inputStream == nil);
  _inputStream = inputStream;
  [self tryCreateSocket];
}

- (void)setOutputStream:(NSOutputStream *)outputStream
{
  // outputStream is from the multipeer session, data written here will
  // be sent to the remote peer
  assert(outputStream && _outputStream == nil);
  _outputStream = outputStream;
  [self tryCreateSocket];
}

- (void)openStreams
{
  // Everything's in place so let's start the streams to let the data flow

  @synchronized(self)
  {
    assert(_inputStream && _outputStream && _socket);

    _inputStream.delegate = self;
    [_inputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [_inputStream open];
    
    _outputStream.delegate = self;
    [_outputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [_outputStream open];

    _relayState = CONNECTED;
  }
}

- (BOOL)canCreateSocket
{
  // Postpone socket creation until we know we have somewhere to send
  // it's data
  return (_inputStream && _outputStream);
}

- (BOOL)tryCreateSocket
{
  // Base class only
  assert(false);
  return NO;
}

- (void)didCreateSocket:(GCDAsyncSocket *)socket
{
  @synchronized(self)
  {
    if (_relayState == STOPPED)
    {
      // It's possible for stop to have been called between opening a socket
      // and it becoming connected, don't attempt to open the streams if that's
      // the case
      return;
    }

    // Socket's been created which means we can open up the stream
    assert(_socket == nil);
   
    // This may be a re-connect of upper layer socket 
    _socket = socket;
    if (_relayState == INITIALIZED)
    {
      [self openStreams];
    }

    assert(_relayState == CONNECTED);
    [_socket readDataWithTimeout:-1 tag:0];
  }
}

- (void)didDisconnectSocket:(GCDAsyncSocket *)socket
{
  assert(socket == _socket);
  _socket.delegate = nil;
  _socket = nil;
}

- (void)stop
{
  @synchronized(self)
  {
    if (_socket)
    {
      _socket.delegate = nil;
      [_socket disconnect];
      _socket = nil;
    }

    if (_inputStream)
    {
      [_inputStream close];
      [_inputStream removeFromRunLoop: [NSRunLoop currentRunLoop] forMode: NSDefaultRunLoopMode];
      _inputStream = nil;
    }

    if (_outputStream)
    {
      [_outputStream close];
      [_outputStream removeFromRunLoop: [NSRunLoop currentRunLoop] forMode: NSDefaultRunLoopMode];
      _outputStream = nil;
    }

    _relayState = STOPPED;
  }
}

- (void)dealloc
{
  assert(_relayState == STOPPED);
}

- (BOOL)writeOutputStream
{
  @synchronized(self)
  {
    if (_outputBuffer.count > 0)
    {
      assert(_outputStream != nil);
      assert([_outputStream hasSpaceAvailable] == YES);

      NSData *data = [_outputBuffer objectAtIndex:0];
      if ([_outputStream write:data.bytes maxLength:data.length] != data.length)
      {
        NSLog(@"ERROR: Writing to output stream");
        return NO;
      }
      [_outputBuffer removeObjectAtIndex:0];
      return YES;
    }
    else
    {
      // Nothing to send
      return NO;
    }
  }
}
 
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
  @synchronized(self)
  {
    assert(sock == _socket);

    // Enqueue, send directly if we're pending
    [_outputBuffer addObject:data];
    if (_outputBufferHasSpaceAvailable)
    {
      BOOL sentData = [self writeOutputStream];
      _outputBufferHasSpaceAvailable = NO;
      assert(sentData == YES);
    }
  }
  [_socket readDataWithTimeout:-1 tag:tag];
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag
{
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
  @synchronized(self)
  {
    assert(_socket == nil || sock == _socket);

    // Usually benign, the upper layer just closed their connection
    // they may want to connect again later

    NSLog(@"%@ relay: socket disconnected", _relayType);

    if (err) 
    {
        NSLog(@"%@ relay: %p disconnected with error %@ ", _relayType, sock, [err description]);
    }

    // Dispose of the socket, it's no good to us anymore
    _socket = nil;
  }
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode
{
  if (aStream == _inputStream) 
  {
    switch (eventCode) 
    {
      case NSStreamEventOpenCompleted:
      {
        //NSLog(@"%@ relay: inputStream opened", _relayType);
      }
      break;

      case NSStreamEventHasSpaceAvailable:
      {
        //NSLog(@"%@ relay: inputStream hasSpace", _relayType);
      }
      break;

      case NSStreamEventHasBytesAvailable:
      {
        const uint BUFFER_LEN = 1024;
        static uint8_t buffer[BUFFER_LEN];

        @synchronized(self)
        {
          NSInteger len = [_inputStream read:buffer maxLength:BUFFER_LEN];
          if (len > 0)
          {
            NSMutableData *toWrite = [[NSMutableData alloc] init];
            [toWrite appendBytes:buffer length:len];

            assert(_socket);
            [_socket writeData:toWrite withTimeout:-1 tag:len];
          }
        }
      }
      break;

      case NSStreamEventEndEncountered:
      {
        //NSLog(@"%@ relay: inputStream closed", _relayType);
      }
      break;

      case NSStreamEventErrorOccurred:
      {
        //NSLog(@"%@ relay: inputStream error", _relayType);
      }
      break;

      default:
      {
        @throw [NSException exceptionWithName:@"UnknownStreamEvent" 
                                       reason:@"Input stream sent unknown event" 
                                     userInfo:nil];
      }
      break;
    }
  }
  else if (aStream == _outputStream)
  {
    switch (eventCode) 
    {
      case NSStreamEventOpenCompleted:
      {
        //NSLog(@"%@ relay: outputStream opened", _relayType);
      }
      break;

      case NSStreamEventHasSpaceAvailable:
      {
        // If we get called here and *don't* send anything we will never get called
        // again until we *do* send something, so record the fact and send directly next
        // next time we put something on the output queue
        BOOL sentData = [self writeOutputStream];
        _outputBufferHasSpaceAvailable = (sentData == NO);
      }
      break;

      case NSStreamEventHasBytesAvailable:
      {
        //NSLog(@"%@ relay: outputStream hasBytes", _relayType);
      }
      break;

      case NSStreamEventEndEncountered:
      {
        //NSLog(@"%@ relay: outputStream closed", _relayType);
      }
      break;

      case NSStreamEventErrorOccurred:
      {
        //NSLog(@"%@ relay: outputStream error", _relayType);
      }
      break;

      default:
      {
        @throw [NSException exceptionWithName:@"UnknownStreamEvent" 
                                       reason:@"Output stream sent unknown event" 
                                     userInfo:nil];
      }
      break;
    }
  }
}
@end
