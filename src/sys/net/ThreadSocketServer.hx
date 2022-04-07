package sys.net;

import sys.net.Socket;
import haxe.io.Bytes;
#if neko
import neko.vm.Thread;
import neko.vm.Lock;
import neko.net.Poll;
#else
import cpp.vm.Thread;
import cpp.vm.Lock;
import cpp.net.Poll;
#end

private typedef ThreadInfos = {
	var id : Int;
	var worker : Thread;
	var poll : Poll;
	var socks : Array<Socket>;
}

private typedef ClientInfos<Client> = {
	var client : Client;
	var sock : Socket;
	var thread : ThreadInfos;
	var buf : Bytes;
	var bufpos : Int;
}

enum ThreadMessage
{
    Stop;
    Socket(s:Socket, cnx:Bool);
}


/**
    The ThreadServer can be used to easily create a multithreaded server where each thread polls multiple connections.
    To use it, at a minimum you must override or rebind clientConnected, readClientMessage, and clientMessage and you must define your Client and Message.
**/
class ThreadSocketServer<Client, Message> {
	public var host(default,null) : String;
	public var port(default,null) : Int;

    /**
        Number of total connections the server will accept.
    **/
	public var numConnections : Int;

    /**
        Number of server threads.
    **/
	public var nthreads : Int;

    /**
        Polling timeout.
    **/
	public var connectLag : Float;

    /**
        Stream to send error messages.
    **/
	public var errorOutput : haxe.io.Output;

    /**
        Space allocated to buffers when they are created.
    **/
	public var initialBufferSize : Int;

    /**
        Maximum size of buffered data read from a socket. An exception is thrown if the buffer exceeds this value.
    **/
	public var maxBufferSize : Int;

    /**
        Minimum message size.
    **/
	public var messageHeaderSize : Int;

    /**
        The most sockets a thread will handle.
    **/
	public var maxSockPerThread : Int;

	var threads : Array<ThreadInfos>;
	var sock : Socket;
    var newClientsWorker : Thread;
	var worker : Thread;

	public function new( host : String, port : Int ) {
		this.host = host;
		this.port = port;
		threads = [];
		nthreads = if( Sys.systemName() == "Windows" ) 150 else 10;
		messageHeaderSize = 1;
		numConnections = 10;
		connectLag = 0.5;
		errorOutput = Sys.stderr();
		initialBufferSize = (1 << 10);
		maxBufferSize = (1 << 16);
		maxSockPerThread = 64;
	}

    /**
        Start the server at the specified host and port.
    **/
	public function start() {
        newClientsWorker = Thread.create( runNewClientsWorker );
        worker = Thread.create( runWorker );
        for( i in 0...nthreads ) {
            var threadInfo:ThreadInfos = {
                id : i,
                worker : null,
                socks : [],
                poll : new Poll( maxSockPerThread )
            };
            threads.push(threadInfo);
            threadInfo.worker = Thread.create( runThreadInfoWorker.bind( threadInfo ) );
        }
	}

    /**
        Stop the server.
    **/
    public function stop() {
        if(newClientsWorker != null)
        {
            newClientsWorker.sendMessage(ThreadMessage.Stop);
            sock.shutdown(true, true);
            sock.close();
            newClientsWorker = null;

            worker.sendMessage(ThreadMessage.Stop);

            for( threadInfo in threads ) {
                var j = threadInfo.socks.length;
                while(j-- > 0)
                {
                    var socket = threadInfo.socks[j];
                    stopClient(socket);
                }
                threadInfo.worker.sendMessage(ThreadMessage.Stop);
            }
        }
    }

    //*********************************************************
    //
    // Private Methods
    //
    //*********************************************************

    function runNewClientsWorker() {
        sock = new Socket();
        sock.bind( new sys.net.Host( host ), port );
        sock.listen( numConnections );

        while( true )
        {
            var msg = Thread.readMessage(false);
            if(msg != null && msg == ThreadMessage.Stop)
            {
                break;
            }
            try addSocket( sock.accept() ) catch(e:Dynamic) logError(e);
        }

        sock = null;
    }

    function runWorker() {
        while( true ) {
            var f:Dynamic = Thread.readMessage(true);
            if(f != null && f == ThreadMessage.Stop)
            {
                worker = null;
                break;
            }

            try f() catch( e : Dynamic ) logError(e);
            try afterEvent() catch( e : Dynamic ) logError(e);
        }
    }

	function runThreadInfoWorker(threadInfo : ThreadInfos ) {
		while( true ) {
			try
            {
                if( threadInfo.socks.length > 0 ) {
                    for( socket in threadInfo.poll.poll( threadInfo.socks, connectLag ) ) {
                        var infos : ClientInfos<Client> = socket.custom;
                        try {
                            readClientData(infos);
                        } catch( e : Dynamic ) {
                            if( !Std.is(e, haxe.io.Eof) && !Std.is(e, haxe.io.Error) )
                                logError(e);
                            stopClient(socket);
                        }
                    }
                }

                while( true ) {
                    var msg:ThreadMessage  = Thread.readMessage( threadInfo.socks.length == 0 );
                    if( msg == null )
                        break;

                    switch(msg)
                    {
                        case ThreadMessage.Stop:
                            for(s in threadInfo.socks)
                            {
                                s.shutdown(true, true);
                            }
                            return;
                        case ThreadMessage.Socket(socket, cnx):
                            if( cnx ) {
                                threadInfo.socks.push( socket );
                            }
                            else if( threadInfo.socks.remove( socket ) ) {
                                var infos : ClientInfos<Client> = socket.custom;
                                work( doClientDisconnected.bind( socket, infos.client ) );
                            }
                    }
                }
            }
            catch( e : Dynamic ) {
				logError(e);
			}
		}
	}

    /**
        Called when the server gets a new connection.
    **/
    function addSocket( s : Socket ) {
//		s.setBlocking( false );     //TODO don't work with range. Receive block errors and it needs to be managed.
        work( addClient.bind( s ) );
    }

    /**
        Send data to a client.
    **/
    function sendData( s : Socket, data : String ) {
        try s.write( data )
        catch( e : Dynamic ) stopClient( s );
    }

    /**
        Internally used to delegate something to the worker thread.
    **/
    function work( f : Void->Void ) {
        if(worker != null)
            worker.sendMessage(f);
    }

    function addClient( socket : Socket ) {
        var start = Std.random( nthreads );
        for( i in 0...nthreads ) {
            var threadInfo = threads[(start + i)%nthreads];
            if( threadInfo.socks.length < maxSockPerThread ) {
                var infos : ClientInfos<Client> = {
                    thread : threadInfo,
                    client : clientConnected( socket ),
                    sock : socket,
                    buf : haxe.io.Bytes.alloc(initialBufferSize),
                    bufpos : 0
                };
                socket.custom = infos;
                infos.thread.worker.sendMessage( ThreadMessage.Socket(socket, true) );
                return;
            }
        }
        refuseClient(socket);
    }

	function readClientData( c : ClientInfos<Client> ) {
		var available = c.buf.length - c.bufpos;
        if( available == 0 ) {
			var newSize = c.buf.length * 2;
			if( newSize > maxBufferSize ) {
				newSize = maxBufferSize;
				if( c.buf.length == maxBufferSize )
					throw "Max buffer size reached";
			}
			var newBuf = Bytes.alloc( newSize );
			newBuf.blit( 0, c.buf, 0, c.bufpos );
			c.buf = newBuf;
			available = newSize - c.bufpos;
		}
		var bytes = c.sock.input.readBytes( c.buf, c.bufpos, available );
		var pos = 0;
		var len = c.bufpos + bytes;
        while( len >= messageHeaderSize ) {
			var m = readClientMessage( c.client, c.buf, pos, len );
			if( m == null )
				break;
			pos += m.len;
			len -= m.len;
            clientMessage(c.client, m.msg);
//            work( clientMessage.bind( c.client, m.msg ) );
		}
		if( pos > 0 )
			c.buf.blit( 0, c.buf, pos, len );
		c.bufpos = len;
	}

	function doClientDisconnected( s : Socket, c : Client ) {
        s.close();
        clientDisconnected(c);
    }

    /**
        Shutdown a client's connection and remove them from the server.
    **/
    function stopClient( s : Socket ) {
        var infos : ClientInfos<Client> = s.custom;
        try s.shutdown(true,true) catch( e : Dynamic ) {};
        infos.thread.worker.sendMessage( ThreadMessage.Socket(s, false) );
    }

	function refuseClient( s : Socket) {
		s.close(); // we have reached maximum number of active clients
	}

    function logError( e : Dynamic ) {
        var stack = haxe.CallStack.exceptionStack();
        if( Thread.current() == worker )
            onError( e, stack );
        else
        {
            work( onError.bind( e, stack ) );
        }
    }

    //*********************************************************
    //
    // Customizable
    //
    //*********************************************************

    /**
        Called when a client connects. Returns a client object.
    **/
    public dynamic function clientConnected( s : Socket ) : Client return null;

    /**
        Called when a client disconnects or an error forces the connection to close.
    **/
    public dynamic function clientDisconnected( c : Client ) {}

    /**
        Called when data has been read from a socket. This method should try to extract a message from the buffer.
        The available data resides in buf, starts at pos, and is len bytes wide. Return the new message and the number of bytes read from the buffer.
        If no message could be read, return null.
    **/
    public dynamic function readClientMessage( c : Client, buf : Bytes, pos : Int, len : Int ) : { msg : Message, len: Int } { return { msg : null, len : len }; }

    /**
        Called when a message has been recieved. Message handling code should go here.
    **/
    public dynamic function clientMessage( c : Client, m : Message ) {}

    /**
        Called after a client connects, disconnects, a message is received, or an update is performed.
    **/
    public dynamic function afterEvent() {}

    /**
        Called when an error has ocurred.
    **/
    public dynamic function onError( e : Dynamic, stack ) {
        var s = try Std.string(e) catch(e2:Dynamic) "???" + try "["+Std.string(e2)+"]" catch(e:Dynamic) "";
        errorOutput.writeString( s + "\n" + haxe.CallStack.toString( stack ) );
        errorOutput.flush();
    }
}
