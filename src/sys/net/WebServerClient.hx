package sys.net;

import sys.net.Socket;
import haxe.io.Bytes;
import haxe.io.Path;
import haxe.net.HTTPRequest;
import haxe.net.HTTPHeaders;
import mime.Mime;

private typedef HTTPReturnCode = {
	var code : Int;
	var text : String;
}

/**
*/
class WebServerClient {

    public inline function log(message:String):Void {
        #if debug
        trace('${fingerprint} INFO: ${message}');
        #end
    }

	var socket : Socket;
	var output : haxe.io.Output;
	var responseCode : HTTPReturnCode;
	var responseHeaders : HTTPHeaders;
    var keepAlive : Bool = false;
    var fingerprint : String;

	public function new( socket : Socket ) {
		this.socket = socket;
		output = socket.output;
	}

	/**
		Read http request
	*/
	public function readRequest( buf : Bytes, pos : Int, len : Int ) : HTTPRequest {
		return HTTPRequest.read( buf, pos, len );
	}

	/**
		Process http request
	*/
	public function processRequest( r : HTTPRequest, ?root : String ) {
        fingerprint = r.fingerprint;
        logHTTPRequest( r );

        keepAlive = r.headers.exists("Connection")
                    && r.headers.get("Connection").toLowerCase() == "keep-alive";
		responseCode = { code : 200, text : "OK" };
		responseHeaders = createResponseHeaders();
	}

	function getFileContentType( path : String ) : String {
        return Mime.lookup(Path.extension( path ));
	}

	function createResponseHeaders() : HTTPHeaders {
		var h = new HTTPHeaders();
		/*
        if( compression ) {
			h.set( 'Content-Encoding', 'gzip' );
		}
		*/
		//h.set( 'Server', WebServer.name );
		return h;
	}

	function sendData( data : String ) {
		responseHeaders.set( 'Content-Length', Std.string( data.length ) );
		sendHeaders();
		//TODO buffered send
		output.writeString( data );
	}

	function sendResponse(code : Int, status : String, content : String = "" ) {
		responseCode = { code : code, text : status };
		responseHeaders.set( 'Content-Length', Std.string( content.length ) );
		sendHeaders();
		output.writeString( content );
	}

	function sendHeaders() {
        logHTTPResponse();

        writeLine( 'HTTP/1.1 ${responseCode.code} ${responseCode.text}' );
		for( k in responseHeaders.keys() ) writeLine( '$k: ${responseHeaders.get(k)}' );
		writeLine();
	}

	inline function writeLine( s : String = "" ) output.writeString( '$s\r\n' );

    inline function date2String(date:Date):String
    {
        #if cpp //TODO  Date.format %Z- not implemented yet
        return DateTools.format(date, '%a, %e %b %Y %I:%M:%S');
        #else
        return DateTools.format(date, '%a, %e %b %Y %I:%M:%S %Z');
        #end
    }

    inline function logHTTPRequest( r : HTTPRequest ) {
        #if debug
        var url = ( r.url == null || r.url.length == 0 ) ? '/' : r.url;
        log( 'Request: ${date2String(Date.now())}');
        log( 'HTTP > ${Std.string( r.method ).toUpperCase()} ${r.url} HTTP/${r.version}');
        for( k in r.headers.keys() )
            log( 'HTTP > $k: ${r.headers.get(k)}');
        #end
    }

    inline function logHTTPResponse() {
        #if debug
        log( 'Response: ${date2String(Date.now())}');
        log( 'HTTP > HTTP/1.1 ${responseCode.code} ${responseCode.text}');
        for( k in responseHeaders.keys() )
            log( 'HTTP > $k: ${responseHeaders.get(k)}');
        #end
    }

    //##########################################################################################
    //
    // UID Generator
    //
    //##########################################################################################

    private static var UID_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

    public static function randomUID(?size:Int=32):String
    {
        var nchars = UID_CHARS.length;
        var uid = new StringBuf();
        for (i in 0 ... size){
            uid.addChar(UID_CHARS.charCodeAt( Std.random(nchars) ));
        }
        return uid.toString();
    }
}
