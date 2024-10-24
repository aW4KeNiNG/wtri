package wtri.handler;

import sys.io.FileSeek;
import sys.io.FileInput;
import wtri.utils.DateUtils;
import sys.FileStat;

using wtri.utils.LogUtils;

class WebServerHandler implements wtri.Handler {
    static inline private var MAX_BUFFER_SIZE:Int = 65536;

    public var path : String;
    public var mimetypes : Map<String,String>;
    public var verbose:Bool = false;
    public var indexFileNames = ['index'];
    public var indexFileTypes = ['html','htm'];

    public function new(path:String, ?verbose:Bool, ?mimetypes:Map<String,String>) {
        this.path = FileSystem.fullPath( path.trim() ).removeTrailingSlashes();
        this.mimetypes = (mimetypes != null) ? mimetypes : #if mime mime.Mime.extensions #else [] #end;
        this.verbose = verbose;
    }

    public function handle(req:Request, res:Response):Bool {

        var _path = '${path}${StringTools.urlDecode(req.path)}'.normalize();
        if(StringTools.startsWith(path, "\\"))
            _path = '/' + _path;

        if(verbose)
            req.logRequest();

        final filePath = findFile( _path );
        if( filePath == null )
        {
            sendCode(res, StatusCode.NOT_FOUND);
            return false;
        }

        var stat:FileStat = FileSystem.stat( filePath );
        var etag:String = getETag(filePath, stat);

        if( req.headers.exists('If-Match') ) {
            var requestETag = req.headers.get('If-Match');
            if(requestETag != "*" && requestETag != etag) {
                sendCode(res, StatusCode.PRECONDITION_FAILED);
                return false;
            }
        }

        if( req.headers.exists('If-None-Match') ) {
            var requestETag = req.headers.get('If-None-Match');
            if(requestETag == "*" && requestETag == etag) {
                sendCode(res, StatusCode.NOT_MODIFIED);
                return false;
            }
        }

        var fromRange:Int = -1;
        var toRange:Int = -1;
        var hasRangeRequest:Bool = req.headers.exists('Range');
        if(hasRangeRequest)
        {
            var range = req.headers.get('Range');
            //TODO - accept multipart/byteranges
            var rangeRE = ~/(\d+)-(\d*)/;
            if(StringTools.startsWith(range, "bytes") && rangeRE.match(range))
            {
                fromRange = Std.parseInt(rangeRE.matched(1));
                var toRangeStr = rangeRE.matched(2);
                if(toRangeStr != "")
                    toRange = Std.parseInt(toRangeStr);
                else if(stat.size > 0)
                    toRange = stat.size - 1;

                if(toRange > stat.size)
                {
                    res.headers.set('Content-Range', 'bytes */${Std.string(stat.size)}');
                    sendCode(res, StatusCode.REQUEST_RANGE_NOT_SATISFIABLE);
                    return false;
                }
                else
                {
                    res.code = StatusCode.PARTIAL_CONTENT;
                    res.headers.set('Content-Range', 'bytes ${Std.string(fromRange)}-${toRange != -1 ? Std.string(toRange) : ""}/${stat.size==0 ? '*' : Std.string(stat.size)}');
                }
            }
            else
            {
                sendCode(res, StatusCode.REQUEST_RANGE_NOT_SATISFIABLE);
                return false;
            }
        }

        if(fromRange < 0)
        {
            fromRange = 0;
        }

        if(toRange < 0)
        {
            toRange = stat.size - 1;
        }

        var isChunked:Bool = hasRangeRequest && (toRange - fromRange) > MAX_BUFFER_SIZE;
        if(isChunked)
        {
            res.headers.set('Transfer-Encoding', 'chunked');
        }

        var host:String = req.headers.get("Host");
        if(host == null || StringTools.startsWith(host, "localhost"))
        {
            res.headers.set('Cache-Control', 'no-cache, no-store, must-revalidate');
            res.headers.set('Pragma', 'no-cache');
            res.headers.set('Expires', '0');
        }

        var contentType : String = null;
//			if( req.headers.exists( 'Accept' ) )
//			{
//				var ctype = req.headers.get( 'Accept' );
//				ctype = ctype.substr( 0, ctype.indexOf( ',' ) ).trim();
//				if( Mime.extension( ctype ) != null ) contentType = ctype;
//			}
        if( contentType == null )
            contentType = getFileContentType(filePath);

        res.headers.set('Content-Type', contentType);
        res.headers.set('Last-Modified', DateUtils.date2String(stat.mtime));
        res.headers.set('ETag', etag);
        res.headers.set('Accept-Ranges', 'bytes');
        res.headers.set('Content-Length', Std.string(toRange - fromRange + 1));
        res.headers.set('Date', DateUtils.date2String(Date.now()));
        res.headers.set('Access-Control-Allow-Origin', '*');
        res.headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
        res.headers.set('Cross-Origin-Opener-Policy', 'same-origin');
//            if(keepAlive)
//            {
//                res.headers.set( 'Connection', 'Keep-Alive' );
//                res.headers.set( 'Keep-Alive', 'timeout=5, max=100' );
//            }

        sendResponseHeaders(res);

        var f:FileInput = File.read( filePath, true );

        toRange += 1;
        var totalRange:Int = toRange - fromRange;

        var offset:Int = fromRange;
        var memoryLength = totalRange > MAX_BUFFER_SIZE ? MAX_BUFFER_SIZE : totalRange;
        var bytes:Bytes = Bytes.alloc(memoryLength);
        var size:Int;

        if(fromRange > 0)
        {
            f.seek(fromRange, FileSeek.SeekCur);
        }

        try
        {
            while(offset < toRange)
            {
                size = (offset + memoryLength > toRange) ? toRange - offset : memoryLength;
//                req.log('Serving from $offset to ${offset+size}. Total: ${size}');

                size = f.readBytes(bytes, 0, size);
                if(isChunked)
                {
                    res.writeLine('${StringTools.hex(size)}');
                    res.write(bytes);
                    res.writeLine();
                }
                else
                {
                    res.write(bytes);
                }

                offset += size;
            }

            f.close();

            if(isChunked)
            {
                res.writeLine("0");
                res.writeLine();
            }
        }
        catch (e:Dynamic)
        {
            f.close();
            throw e;
        }

        return true;
    }

    function findFile(path:String):String {
		if(!FileSystem.exists(path))
			return null;
		if(FileSystem.isDirectory(path))
			return findIndexFile(path);
		return path;
	}

    function findIndexFile(path:String):String
    {
		final r = new EReg('(${indexFileNames.join("|")}).(${indexFileTypes.join("|")})$', '');
		for(f in FileSystem.readDirectory(path))
			if(r.match(f))
				return path +'/'+ r.matched(1) + '.' + r.matched(2);
		return null;
	}

    function getFileContentType(path:String):String
    {
		final x = path.extension().toLowerCase();
		return mimetypes.exists(x) ? mimetypes.get(x) : 'application/octet-stream';
	}

    function getETag(url:String, stat:FileStat):String
    {
        return '"${haxe.crypto.Md5.encode('$url - ${stat.mtime.getTime()} - ${stat.size}')}"';
    }

    function sendResponseHeaders(res:Response)
    {
        if(verbose)
            res.logResponse();
        res.writeHead();
    }

    function sendCode(res:Response, code:StatusCode)
    {
        res.code = code;
        sendResponseHeaders(res);
    }
}
