package wtri.utils;

class DateUtils {
    inline static public function date2String(date:Date):String
    {
        #if cpp //TODO  Date.format %Z- not implemented yet
        return DateTools.format(date, '%a, %e %b %Y %I:%M:%S');
        #else
        return DateTools.format(date, '%a, %e %b %Y %I:%M:%S %Z');
        #end
    }
}
