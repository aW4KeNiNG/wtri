package wtri;

import haxe.CallStack.StackItem;
import sys.thread.Mutex;
import sys.thread.Thread;
import wtri.utils.LogUtils;

enum ThreadMessage
{
    Stop;
    Error(error:Dynamic, stack:Array<StackItem>);
    SendSocket(s:sys.net.Socket);
}

class ThreadServer
{

    public var listening(default,null) = false;
    public var handle : Request->Response->Void;
    public var threads(default,null):Int;
    public var port(default, null):Int;

    var mainSocket:sys.net.Socket;
    var newClientsWorker:Thread;
    var workers:Array<Thread> = [];
    var sockets:Array<TCPSocket> = [];
    var freeWorkers:Array<Thread> = [];
    var freeWorkersMutex:Mutex = new Mutex();
    var socketsMutex:Mutex = new Mutex();

    public function new(handle:Request->Response->Void, threads:Int = 8)
    {
        this.handle = handle;
        this.threads = threads;
    }
    
    public function listen(port:Int, host:String = 'localhost', uv = false, maxConnections = 100):ThreadServer
    {
        if(!listening)
        {
            this.port = port;
            listening = true;
            for(i in 0...threads)
            {
                workers.push(Thread.create(runWorker));
            }

            newClientsWorker = Thread.create( () -> runNewClientsWorker(port, host, maxConnections) );
        }

        return this;
    }

    public function stop():ThreadServer
    {
        if(listening && newClientsWorker != null)
        {
            listening = false;
            for(worker in workers)
            {
                worker.sendMessage(ThreadMessage.Stop);
            }
            workers.splice(0, workers.length);

            socketsMutex.acquire();
            for(socket in sockets)
            {
                socket.socket.shutdown(true, true);
                socket.socket.close();
            }
            sockets.splice(0, sockets.length);
            socketsMutex.release();

            newClientsWorker.sendMessage(ThreadMessage.Stop);
            mainSocket.shutdown(true, true);
            mainSocket.close();
            newClientsWorker = null;
        }
        return this;
    }

    function process(socket:TCPSocket, ?input:haxe.io.Input)
    {
        socketsMutex.acquire();
        sockets.push(socket);
        socketsMutex.release();

        final req = new Request(socket, input);
        final res = req.createResponse();
        try
        {
            handle(req, res);
            switch res.headers.get(Connection)
            {
                case null,'close': socket.close();
            }
        }
        catch( e : Dynamic )
        {
            logError(req, e);
        }

        socketsMutex.acquire();
        sockets.remove(socket);
        socketsMutex.release();
    }

    function runNewClientsWorker(port:Int, host:String, numConnections:Int)
    {
        mainSocket = new sys.net.Socket();
        mainSocket.bind( new sys.net.Host( host ), port );
        mainSocket.listen( numConnections );

        while(listening)
        {
            var msg = Thread.readMessage(false);
            if(msg != null && msg == ThreadMessage.Stop)
            {
                switch(msg)
                {
                    case ThreadMessage.Stop:
                        mainSocket = null;
                        return;

                    case ThreadMessage.Error(error, stack):
                        LogUtils.logError(error, stack);

                    case _:
                }
            }

            var socket:sys.net.Socket = null;
            try
            {
                socket = mainSocket.accept();
            }
            catch(e:Dynamic)
            {
            }

            if(socket != null)
                sendSocketToWorker(socket);
        }
    }

    function runWorker()
    {
        while(listening) {
            freeWorkersMutex.acquire();
            freeWorkers.push(Thread.current());
            freeWorkersMutex.release();

            var msg = Thread.readMessage(true);
            if(msg != null)
            {
                switch(msg)
                {
                    case ThreadMessage.Stop:
                        freeWorkersMutex.acquire();
                        freeWorkers.remove(Thread.current());
                        freeWorkersMutex.release();

                    case ThreadMessage.SendSocket(socket):
                        process(new wtri.net.Socket.TCPSocket(socket), socket.input);

                    case _:
                }
            }
        }
    }

    function sendSocketToWorker(sock:sys.net.Socket)
    {
        while(listening)
        {
            freeWorkersMutex.acquire();
            if(freeWorkers.length > 0)
            {
                var worker = freeWorkers.pop();
                freeWorkersMutex.release();
                worker.sendMessage(ThreadMessage.SendSocket(sock));
                break;
            }
            else
                freeWorkersMutex.release();

            Sys.sleep(0.05);
        }
    }

    function logError(request:Request, e:Dynamic)
    {
        if(newClientsWorker != null)
            newClientsWorker.sendMessage(ThreadMessage.Error(e, haxe.CallStack.exceptionStack()));
    }
}