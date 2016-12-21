package sys.net;

/*
typedef ThreadServer = 
	#if cpp
	cpp.net.ThreadServer<Client,Message>
	#elseif neko
	neko.net.ThreadServer<Client,Message>
	#end;
*/

import sys.net.Socket;
import haxe.io.Bytes;
#if cpp
import cpp.vm.Thread;
import cpp.vm.Lock;
import cpp.net.Poll;
#elseif neko
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

class ThreadSocketServer<Client, Message> {

	public dynamic function clientConnected( s : Socket ) : Client return null;
	public dynamic function clientDisconnected( c : Client ) {}
	public dynamic function readClientMessage( c : Client, buf : Bytes, pos : Int, len : Int ) : { msg : Message, len: Int } { return { msg : null, len : len }; }
	public dynamic function clientMessage( c : Client, m : Message ) {}
//	public dynamic function update() {}
	public dynamic function afterEvent() {}
	public dynamic function onError( e : Dynamic, stack ) {
		var s = try Std.string(e) catch(e2:Dynamic) "???" + try "["+Std.string(e2)+"]" catch(e:Dynamic) "";
		errorOutput.writeString( s + "\n" + haxe.CallStack.toString( stack ) );
		errorOutput.flush();
	}

	public var host(default,null) : String;
	public var port(default,null) : Int;
	public var numConnections : Int;

	public var nthreads : Int;
	public var connectLag : Float;
	public var errorOutput : haxe.io.Output;
	public var initialBufferSize : Int;
	public var maxBufferSize : Int;
	public var messageHeaderSize : Int;
//	public var updateTime : Float;
	public var maxSockPerThread : Int;

	var threads : Array<ThreadInfos>;
	var sock : Socket;
    var newClientsWorker : Thread;
	var worker : Thread;
//	var timer : Thread;

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
//		updateTime = 1;
	}

	public function start() {
		initServer();
	}

    public function stop() {
        if(newClientsWorker != null)
        {
            newClientsWorker.sendMessage(ThreadMessage.Stop);
            if(sock != null)
            {
                #if mobile
                sock.shutdown(true, true);
                #else
                sock.close();
                #end
            }
            newClientsWorker = null;
        }
    }

	public function addSocket( s : Socket ) {
//		s.setBlocking( false );     //TODO don't work with range. Receive block errors and it needs to be managed.
		work( addClient.bind( s ) );
	}

	public function sendData( s : Socket, data : String ) {
		try s.write( data )
        catch( e : Dynamic ) stopClient( s );
	}

	public function work( f : Void->Void ) {
        if(worker != null)
		    worker.sendMessage(f);
	}

    //*********************************************************
    //
    // Private Methods
    //
    //*********************************************************

    function initServer() {
        newClientsWorker = Thread.create( runNewClientsWorker );
        worker = Thread.create( runWorker );
//        timer = Thread.create( runTimer );
        for( i in 0...nthreads ) {
            var threadInfo:ThreadInfos = {
                id : i,
                worker : null,
                socks : new Array(),
                poll : new Poll( maxSockPerThread )
            };
            threads.push(threadInfo);
            threadInfo.worker = Thread.create( runThreadInfoWorker.bind( threadInfo ) );
        }
    }

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

        sock.shutdown(true, true);
        sock.close();
        sock = null;

//        timer.sendMessage(ThreadMessage.Stop);
        worker.sendMessage(ThreadMessage.Stop);

        for( i in 0...nthreads ) {
            var threadInfos = threads[i];
            var j = threadInfos.socks.length;
            while(j-- > 0)
            {
                var socket = threadInfos.socks[j];
                stopClient(socket);
            }
            threadInfos.worker.sendMessage(ThreadMessage.Stop);
        }
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
                            threadInfo.socks.remove(socket);
                            if( !Std.is(e, haxe.io.Eof) && !Std.is(e, haxe.io.Error) )
                                logError(e);
                            work(doClientDisconnected.bind(socket,infos.client));
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
                                try #if mobile s.shutdown(true,true) #else sock.close(); #end catch( e : Dynamic ) {};
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

//    function runTimer() {
//        var l = new Lock();
//        while( true ) {
//            l.wait( updateTime );
//
//            var msg = Thread.readMessage(false);
//            if((msg != null && msg == ThreadMessage.Stop) || worker == null)
//            {
//                timer = null;
//                break;
//            }
//            work( update );
//        }
//    }

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
			var nsize = c.buf.length * 2;
			if( nsize > maxBufferSize ) {
				nsize = maxBufferSize;
				if( c.buf.length == maxBufferSize )
					throw "Max buffer size reached";
			}
			var nbuf = Bytes.alloc( nsize );
			nbuf.blit( 0, c.buf, 0, c.bufpos );
			c.buf = nbuf;
			available = nsize - c.bufpos;
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
			work( clientMessage.bind( c.client, m.msg ) );
		}
		if( pos > 0 )
			c.buf.blit( 0, c.buf, pos, len );
		c.bufpos = len;
	}

	function doClientDisconnected( s : Socket, c : Client ) {
		try s.close() catch( e : Dynamic ) {};
		clientDisconnected(c);
	}

    public function stopClient( s : Socket ) {
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
            work( onError.bind( e, stack ) );
    }
}
