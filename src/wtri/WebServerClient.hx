package wtri;

import haxe.net.HTTPRequest;
import sys.io.FileInput;
import sys.FileStat;
import sys.io.FileSeek;
import sys.net.WebServerClient;
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;
import sys.net.Socket;
import haxe.Template;
import haxe.net.HTTPHeaders;
import haxe.net.HTTPStatusCode;
import mime.Mime;

using StringTools;

class WebServerClient extends sys.net.WebServerClient
{
    static inline private var MAX_BUFFER_SIZE:Int = 1048576;

	public var indexFileNames : Array<String>;
	public var indexFileTypes : Array<String>;

    public var isBlocked:Bool = false;

	var root : String;

    var isChunked:Bool;

	public function new( socket : Socket, root : String ) {

		super( socket );
		this.root = root;

		indexFileNames = ['index'];
		indexFileTypes = ['html','htm'];
	}

	/**
		Process http request
	*/
	public override function processRequest( r : HTTPRequest, ?root : String ) {

        super.processRequest( r, root );
		
		var path = (root != null) ? root : this.root;
		path += r.url;

		var filePath = findFile( path );
		if( filePath == null ) {
			fileNotFound( path, r.url );
		} else {
            var stat:FileStat = FileSystem.stat( path );
            var etag:String = getETag(path);

            if( r.headers.exists( 'If-Match' ) ) {
                var requestETag = r.headers.get( 'If-Match' );
                if(requestETag != "*" && requestETag != etag) {
                    sendResponse(HTTPStatusCode.PRECONDITION_FAILED, "Precondition Failed");
                    return;
                }
            }

            if( r.headers.exists( 'If-None-Match' ) ) {
                var requestETag = r.headers.get( 'If-None-Match' );
                if(requestETag == "*" && requestETag == etag) {
                    sendResponse(HTTPStatusCode.NOT_MODIFIED, "Not Modified");
                    return;
                }
            }

            var fromRange:Int = -1;
            var toRange:Int = -1;
            if( r.headers.exists( 'Range' ) ) {
                var range = r.headers.get( 'Range' );
                //TODO - accept multipart/byteranges
                if(StringTools.startsWith(range, "bytes"))
                {
                    var rangeRE = ~/(\d+)-(\d*)/;
                    if(rangeRE.match(range))
                    {
                        fromRange = Std.parseInt(rangeRE.matched(1));
                        var toRangeStr = rangeRE.matched(2);
                        if(toRangeStr != "")
                            toRange = Std.parseInt(toRangeStr);

                        if(toRange != -1)
                        {
                            if(toRange > stat.size)
                            {
                                sendResponse(HTTPStatusCode.REQUEST_RANGE_NOT_SATISFIABLE, "Requested range not satisfiable");
                                return;
                            }
                            else
                            {
                                responseCode = { code : 206, text : "Partial Content" };
                                responseHeaders.set( 'Content-Range', 'bytes ${Std.string(fromRange)}-${Std.string(toRange)}/${Std.string(toRange-fromRange)}' );
                            }
                        }
                    }
                }
                else
                {
                    sendResponse(HTTPStatusCode.BAD_REQUEST, "Bad Request");
                    return;
                }
            }

            if(fromRange < 0)
            {
                fromRange = 0;
            }

            if(toRange < 0)
            {
                toRange = stat.size;
            }

            isChunked = false;//hasRange;  //TODO - disabled for now. It doesn't work with videos in Chrome
            //isChunked = totalRange > MAX_BUFFER_SIZE;
            if(isChunked)
            {
                responseHeaders.set( 'Transfer-Encoding', 'chunked' );
            }

            var contentType : String = null;
//			if( r.headers.exists( 'Accept' ) ) {
//				var ctype = r.headers.get( 'Accept' );
//				ctype = ctype.substr( 0, ctype.indexOf( ',' ) ).trim();
//				if( Mime.extension( ctype ) != null ) contentType = ctype;
//			}
            if( contentType == null )
                contentType = getFileContentType( filePath );

            responseHeaders.set( 'Content-Type', contentType );
            responseHeaders.set( 'Last-Modified', date2String(stat.mtime) );
            responseHeaders.set( 'ETag', etag );
//            responseHeaders.set( 'Accept-Ranges', 'bytes' );  //TODO - not play videos in Chrome
            responseHeaders.set( 'Accept-Ranges', 'none' );
            responseHeaders.set( 'Content-Length', Std.string(toRange - fromRange) );
            responseHeaders.set( 'Date', date2String(Date.now()) );

//            if(keepAlive)
//            {
//                responseHeaders.set( 'Connection', 'Keep-Alive' );
//                responseHeaders.set( 'Keep-Alive', 'timeout=5, max=100' );
//            }

            var f:FileInput = File.read( path, true );
            if(fromRange > 0)
            {
                f.seek(fromRange, FileSeek.SeekCur);
            }

            try
            {
                sendHeaders();

                sendFile(filePath, fromRange, toRange);

                log("End");
                f.close();
            }
            catch (e:Dynamic)
            {
                log('Server exception $e');
                f.close();
                throw e;

                //TODO - error 500 Internal Server Error if it is not blocked or eof
            }
        }
    }

	override function createResponseHeaders() : HTTPHeaders {
		var h = super.createResponseHeaders();
		h.set( 'Server', WebServer.name );
		return h;
	}

	function findFile( path : String ) : String {
		if( !FileSystem.exists( path ) )
			return null;
		if( FileSystem.isDirectory( path ) )
			return findIndexFile( path );
		return path;
	}

	function findIndexFile( path : String ) : String {
		var r = new EReg( '(${indexFileNames.join("|")}).(${indexFileTypes.join("|")})$', '' );
		for( f in FileSystem.readDirectory( path) ) {
			if( r.match( f ) ) {
				return path + r.matched(1) + '.' + r.matched(2);
			}
		}
		return null;
	}

	function fileNotFound( path : String, url : String, html : String = null ) {
		if( !FileSystem.exists( path ) || !FileSystem.isDirectory( path ) ) {
            sendResponse(HTTPStatusCode.NOT_FOUND, "Not Found");
			return;
		}

		var now = Date.now();
		var dirs = new Array<Dynamic>();
		var files = new Array<Dynamic>();
		for( f in FileSystem.readDirectory( path ) ) {
			var p = path+f;
			var stat = FileSystem.stat( p );
			var mtime = stat.mtime;
			var modified = '';
			if( now.getFullYear() != mtime.getFullYear() ) modified += mtime.getFullYear()+'-';
			modified += getDateTime( mtime );
			var o : Dynamic = { name : f, path : f, modified : modified };
			if( FileSystem.isDirectory( p ) ) {
				o.items = FileSystem.readDirectory( p ).length;
				dirs.push( o );
			} else {
				o.size =
					if( stat.size > 1024*1024 ) Std.int( stat.size/(1024*1024) )+'MB';
					else if( stat.size > 1024 ) Std.int( stat.size/1024 )+'KB';
					else stat.size;
				files.push( o );
			}
		}
		var ctx = {
			//parent : '../',
			path : url,
			dirs : dirs,
			files : files, 
			address : WebServer.name+' '+socket.host().host+':'+socket.host().port,
		};
		sendData( createTemplateHtml( 'index', ctx ) );
	}

	function sendFile(path : String, fromRange:Int, toRange:Int) {
        var totalRange:Int = toRange - fromRange;

        var offset:Int = fromRange;
        var memoryLength = totalRange > MAX_BUFFER_SIZE ? MAX_BUFFER_SIZE : totalRange;
        var bytes:Bytes = Bytes.alloc(memoryLength);
        var size:Int;
        while(offset < toRange)
        {
            size = memoryLength;
            if(offset + size > toRange)
                size = toRange - offset;

            log('Serving from $offset to ${offset+size}');
            f.readBytes(bytes, 0, size);

            if(isChunked)
            {
                writeLine('${StringTools.hex(size)}');
                output.writeFullBytes(bytes, 0, size);
                writeLine();
            }
            else
            {
                output.writeFullBytes(bytes, 0, size);
            }


            offset += size;
        }

        if(isChunked)
        {
            writeLine("0");
            writeLine();
        }
    }

    function getETag(url:String):String {
        return '"${haxe.crypto.Md5.encode('$url - ${stat.mtime.getTime()}')}"';
    }

	static inline function getDateTime( ?time : Date ) : String {
		if( time == null ) time = Date.now();
		return
			#if cpp
			time.toString()
			#else
			DateTools.format( time, '%d-%B %H:%M:%S' )
			#end;
	}

	static inline function createTemplate( id : String ) : Template {
		return new Template( haxe.Resource.getString( id ) );
	}

	static inline function createTemplateHtml( id : String, ctx : Dynamic ) : String {
		return createTemplate( id ).execute( (ctx == null) ? {} : ctx );
	}

}
