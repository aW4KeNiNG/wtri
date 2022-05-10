package wtri.utils;

class UIDUtils {
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
