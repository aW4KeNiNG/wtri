package sys.net;

import haxe.io.Bytes;
import haxe.net.HTTPError;
import haxe.net.HTTPRequest;

class WebServer<Client:WebServerClient> extends ThreadSocketServer<Client,HTTPRequest> {

	public function new( host : String, port : Int ) {
		super( host, port );
	}

	public override function clientMessage( c : Client, m : HTTPRequest ) {
		c.processRequest( m );
	}

	public override function readClientMessage( c : Client, buf : Bytes, pos : Int, len : Int ) : { msg : HTTPRequest, len : Int } {
		var r : HTTPRequest = null;
		try r = c.readRequest( buf, pos, len ) catch(e:HTTPError) {
			trace(e);
		} catch(e:String) {
			trace(e);
			return { msg : null, len : len };
		}
		return { msg : r, len : len };
	}

}
