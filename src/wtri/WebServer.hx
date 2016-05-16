package wtri;

import Sys.println;
import sys.FileSystem;
import sys.net.Socket;

using StringTools;
using haxe.io.Path;

/**
	Development web server
*/
class WebServer extends sys.net.WebServer<WebServerClient> {

	public static var name = "Haxe Development Server";

	/* Web server root path in filesystem */
	public var root : String;

	public function new( host : String, port : Int, root : String ) {
		root = FileSystem.fullPath( root.trim() ).addTrailingSlash();
		super( host, port );
		this.root = root;
	}

	public override function start() {
		println( 'Starting webserver: $host:$port:$root' );
		super.start();
	}

	public override function clientConnected( s : Socket ) : WebServerClient {
		return new WebServerClient( s, root );
	}
}
