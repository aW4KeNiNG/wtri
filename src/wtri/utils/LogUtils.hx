package wtri.utils;

import haxe.CallStack.StackItem;
import wtri.utils.DateUtils;

class LogUtils {
    static public var logFunc:Dynamic->?haxe.PosInfos->Void = haxe.Log.trace;

    inline static public function log(tag:String, message:String):Void {
        logFunc('${tag}: ${message}');
    }

    inline static public function logInfo(message:String):Void {
        log("INFO", message);
    }

    inline static public function logError(e:Dynamic, ?stack:Array<StackItem>) {
        var s = try Std.string(e) catch(e2:Dynamic) "???" + try "["+Std.string(e2)+"]" catch(e:Dynamic) "";
        log("ERROR", s + "\n" + (stack != null ? haxe.CallStack.toString(stack) : ""));
    }

    inline static public function logRequest(r:Request) {
        var url = ( r.path == null || r.path.length == 0 ) ? '/' : r.path;
        var lines = [];
        lines.push('${r.fingerprint} Request: ${DateUtils.date2String(Date.now())}');
        lines.push('${r.fingerprint} HTTP > ${Std.string( r.method ).toUpperCase()} ${r.path} ${r.protocol}');
        for( k in r.headers.keys() )
            lines.push('${r.fingerprint} HTTP > $k: ${r.headers.get(k)}');
        logInfo(lines.join('\n'));
    }

    inline static public function logResponse(r:Response) {
        var lines = [];
        lines.push('${r.fingerprint} Response: ${DateUtils.date2String(Date.now())}');
        lines.push('${r.fingerprint} HTTP > ${r.protocol} ${r.code} ${StatusMessage.fromStatusCode(r.code)}');
        for( k in r.headers.keys() )
            lines.push('${r.fingerprint} HTTP > $k: ${r.headers.get(k)}');
        logInfo(lines.join('\n'));
    }
}
