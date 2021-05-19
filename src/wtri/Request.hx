package wtri;

class Request {

    public var stream : wtri.Stream;

    public final method : Method;
    public final path : String;
    public final params : Map<String,String>;
    public final protocol : String;
    public final headers = new Map<String,String>();
    //public maxHeadersCount = 2000;

    public var data : Bytes;

    public function new( stream : wtri.Stream, method : Method, path : String, params : Map<String,String>, protocol : String ) {
        this.stream = stream;
        this.method = method;
        this.path = path;
        this.params = params;
        this.protocol = protocol;
    }
}
