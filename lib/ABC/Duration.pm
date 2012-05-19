use v6;

role ABC::Duration {
    has $.ticks;

    multi sub duration-from-parse($top) is export { #OK
        ABC::Duration.new(:ticks(($top ?? +~$top !! 1).Int));
    }
    
    multi sub duration-from-parse($top, $bottom) is export { #OK
        # $*ERR.say: :$top.perl;
        # $*ERR.say: :$bottom.perl;
        ABC::Duration.new(:ticks(($top ?? +~$top !! 1).Int / ($bottom ?? +~$bottom !! 2).Int));
    }
    
    our method duration-to-str() {
        given $.ticks {
            when 1 { ""; }
            when 1/2 { "/"; }
            when Int { .Str; }
            when Rat { $_.denominator == 1 ?? ~$_.numerator !! $_.numerator ~ "/" ~ $_.denominator; }
            die "Duration must be Int or Rat, but it's { .WHAT }";
        }
    }
}
