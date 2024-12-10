use v6;
use ABC::Header;
use ABC::Tune;
use ABC::Grammar;
use ABC::Actions;
use ABC::Duration; #OK
use ABC::Note;
use ABC::LongRest;
use ABC::Utils;
use ABC::KeyInfo;
use ABC::Context;

my $use-ABC-line-breaks = True; # false will use Lilypond's judgment

my %accidental-map = ( ''  => "",
                       '='  => "",
                       '^'  => "is",
                       '^^' => "isis",
                       '_'  => "es",
                       '__' => "eses" );

my %octave-map = ( -3 => ",,",
                   -2 => ",",
                   -1 => "",
                    0 => "'",
                    1 => "''",
                    2 => "'''" );

my %unrecognized_gracings;
my %substitutes;
my %title-skips;

my $spacing-comment = ''; # '%{ spacing %}';

sub start-lilypond($out, $paper-size) is export {
    $out.say: '\\version "2.19.83"';
    $out.say: "#(set-default-paper-size \"{$paper-size}\")";
    $out.say: '#(define-bar-line ".|:-|." "|." ".|:" ".|")';
}
                
sub sanitize-quotation-marks($string, :$escape-number-sign?) is export {
    my $s = $string;
    $s.=subst(/^^ '"' (\S)/, {"“$0"}, :global);
    $s.=subst(/<?after \s> '"' (\S)/, {"“$0"}, :global);
    $s.=subst(/'"'/, "”", :global);
    $s.=subst(/"'s" $/, {"’s"}, :global);
    $s.=subst(/"'s" <?before \s>/, {"’s"}, :global);
    $s.=subst(/<!wb>"'"(\S)/, {"‘$0"}, :global);
    $s.=subst(/"'"/, "’", :global);
    $s.=subst(/ "#" /, "＃", :global) if $escape-number-sign;
    
    my @subs = %substitutes.keys;
    $s.=subst(/ (@subs) /, { %substitutes{$0} }, :global);
    
    $s;
}

class LilypondContext {
    has ABC::Context $.context;
    
    method new($key-name, $meter, $length, :$current-key-info) {
        self.bless(context => ABC::Context.new($key-name, $meter, $length, :$current-key-info));
    }

    method bar-line { $.context.bar-line; }

    method get-Lilypond-pitch(ABC::Note $abc-pitch) {
        my $real-accidental = $.context.working-accidental($abc-pitch);
        
        my $octave = +($abc-pitch.basenote ~~ 'a'..'z') + $.context.key-info.octave-shift;
        given $abc-pitch.octave {
            when !*.defined { } # skip if no additional octave info
            when /\,/ { $octave -= $abc-pitch.octave.chars }
            when /\'/ { $octave += $abc-pitch.octave.chars }
        }
        
        $abc-pitch.basenote.lc ~ %accidental-map{$real-accidental} ~ %octave-map{$octave};
    }

    method get-Lilypond-duration(ABC::Duration $abc-duration) {
        my $ticks = $abc-duration.ticks.Rat * $.context.length;
        my $dots = "";
        given $ticks.numerator {
            when 3 { $dots = ".";  $ticks *= 2/3; }
            when 7 { $dots = ".."; $ticks *= 4/7; }
        }
        die "Don't know how to handle duration { $abc-duration.ticks }" unless is-a-power-of-two($ticks);
        die "Don't know how to handle duration { $abc-duration.ticks }" if $ticks > 4;
        if $ticks == 4 { 
            "\\longa" ~ $dots;
        } elsif $ticks == 2 { 
            "\\breve" ~ $dots;
        } else {
            $ticks.denominator ~ $dots;
        }
    }
    
    method meter-to-string() {
        given $.context.meter {
            when "none" { "" }
            when "C" { "\\time 4/4" }
            when "C|" { "\\time 2/2" }
            when "3/4" { "\\time 3/4 \\set Timing.beamExceptions = #'()"}
            when "6/4" { "\\time 6/4 \\set Timing.beatStructure = 2,2,2"}
            "\\time { $.context.meter } ";
        }
    }

    method ticks-in-measure() {
        given $.context.meter {
            when "C" | "C|" { 1 / $.context.length; }
            when "none" { Inf }
            $.context.meter / $.context.length;
        }
    }

    method get-Lilypond-measure-length() {
        given $.context.meter.trim {
            when "C" | "C|" | "4/4" { "1" }
            when "3/4" | 6/8 { "2." }
            when "2/4" { "2" }
        }
    }
    
    method key-to-string() {
        my $sf = $.context.key-info.key.flatmap({ "{.key}{.value}" }).sort.Str.lc;
        my $major-key-name;
        given $sf {
            when ""                     { $major-key-name = "c"; }
            when "f^"                   { $major-key-name = "g"; }
            when "c^ f^"                { $major-key-name = "d"; }
            when "c^ f^ g^"             { $major-key-name = "a"; }
            when "c^ d^ f^ g^"          { $major-key-name = "e"; }
            when "a^ c^ d^ f^ g^"       { $major-key-name = "b"; }
            when "a^ c^ d^ e^ f^ g^"    { $major-key-name = "fis"; }
            when "a^ b^ c^ d^ e^ f^ g^" { $major-key-name = "cis"; }
            when "b_"                   { $major-key-name = "f"; }
            when "b_ e_"                { $major-key-name = "bes"; }
            when "a_ b_ e_"             { $major-key-name = "ees"; }
            when "a_ b_ d_ e_"          { $major-key-name = "aes"; }
            when "a_ b_ d_ e_ g_"       { $major-key-name = "des"; }
            when "a_ b_ c_ d_ e_ g_"    { $major-key-name = "ges"; }
            when "a_ b_ c_ d_ e_ f_ g_" { $major-key-name = "ces"; }
        }
        "\\key $major-key-name \\major\n";
    }
    
    method clef-to-string() {
        my $lilypond-clef = "treble";
        given $.context.key-info.clef {
            when not .defined { }
            when "treble" | "alto" | "tenor" | "bass" { $lilypond-clef = ~$.context.key-info.clef; }
        }
        "\\clef $lilypond-clef";
    }
}

sub get-field-if-there($header, $field) {
    my @things = $header.get($field)>>.value;
    ?@things ?? @things[0] !! "";
}

class TuneConvertor {
    has $.context;
    has $.log;

    method new($key, $meter, $length, $log) {
        self.bless(:context(LilypondContext.new($key, $meter, $length)), :$log);
    }

    # MUST: this is context dependent too
    method Duration($element) {
        $element.value ~~ ABC::Duration ?? $element.value.ticks !! 0;
    }
    
    method StemPitchToLilypond($stem) {
        given $stem {
            when ABC::Note {
                $.context.get-Lilypond-pitch($stem)
            }

            when ABC::Stem {
                "<" ~ $stem.notes.map({
                    $.context.get-Lilypond-pitch($_) ~ ($_.is-tie ?? '~' !! '')
                }).join(' ') ~ ">"
            }

            die "Unrecognized alleged stem: " ~ $stem.perl;
        }
    }
    
    method StemToLilypond($stem, $suffix = "") {
        " " ~ self.StemPitchToLilypond($stem)
            ~ $.context.get-Lilypond-duration($stem)
            ~ ($stem.is-tie ?? '~' !! '')
            ~ $suffix
            ~ " ";
    }
    
    method WrapBar($lilypond-bar, $duration, :$might-be-parital?) {
        my $ticks-in-measure = $.context.ticks-in-measure;
        my $result = "";

        if $ticks-in-measure == Inf {
            $result ~= "\\cadenzaOn ";
            
            my @chunks = $lilypond-bar.split($spacing-comment);
            for @chunks -> $chunk {
                if $chunk !~~ /"["/ && $chunk.comb(/\d+/).grep(* > 4) > 1 {
                    $result ~= $chunk.subst(/<?after \S> \s/, { "[ " }) ~ "]";
                } else {
                    $result ~= $chunk;
                }
            }
            
            $result ~= " \\cadenzaOff";
        } else {
            if $might-be-parital && $duration % $ticks-in-measure != 0 {
                my $note-length = 1 / $.context.context.length;
                my $count = $duration % $ticks-in-measure;
                if $count ~~ Rat {
                    die "Strange partial measure found: $lilypond-bar" unless is-a-power-of-two($count.denominator);

                    while $count.denominator > 1 {
                        $note-length *= 2; # makes twice as short
                        $count *= 2;       # makes twice as long
                    }
                }
                $result = "\\partial { $note-length }*{ $count } ";
            }
            $result ~= $lilypond-bar;
        }

        $result; 
    }

    sub token-is-space($token) {
        # this probably needs to get smarter about barline
        so $token.key eq "spacing" | "endline" | "barline" | "end_nth_repeat" | "inline_field";
    }

    method SectionToLilypond(@elements, $out, :$first-bar-might-need-partial?, :$next-section-is-repeated?) {
        my $first-bar = True;
        my $notes = "";
        my $lilypond = "";
        my $duration = 0;
        my $chord-duration = 0;
        my $suffix = "";
        my $in-slur = False;
        for @elements.kv -> $i, $element {
            $duration += self.Duration($element);
            $chord-duration += self.Duration($element);
            given $element.key {
                when "stem" { 
                    $lilypond ~= self.StemToLilypond($element.value, $suffix); 
                    $suffix = ""; 
                }
                when "rest" { 
                    $lilypond ~=  " r{ $.context.get-Lilypond-duration($element.value) }$suffix "; 
                    $suffix = ""; 
                }
                when "tuplet" {
                    given $element.value.tuple {
                        when 2 { $lilypond ~= " \\times 3/2 \{"; }
                        when 3 { $lilypond ~= " \\times 2/3 \{"; }
                        when 4 { $lilypond ~= " \\times 3/4 \{"; }
                        $lilypond ~= " \\times 2/{ $element.value.tuple } \{";
                    }
                    $lilypond ~= self.StemToLilypond($element.value.notes[0], "[");
                    for 1..($element.value.notes - 2) -> $i {
                        $lilypond ~= self.StemToLilypond($element.value.notes[$i]);
                    }
                    $lilypond ~= self.StemToLilypond($element.value.notes[*-1], "]");
                    $lilypond ~= " } ";  
                    $suffix = "";
                }
                when "broken_rhythm" {
                    $lilypond ~= self.StemToLilypond($element.value.effective-stem1, $suffix);
                    # MUST: handle interior graciings
                    $lilypond ~= self.StemToLilypond($element.value.effective-stem2);
                    $suffix = "";
                }
                when "gracing" {
                    given $element.value {
                        when "~" { $suffix ~= "\\turn"; }
                        when "." { $suffix ~= "\\staccato"; }
                        when "T" { $suffix ~= "\\trill"; }
                        when "P" { $suffix ~= "\\prall"; }
                        when "L" { $suffix ~= "\\accent"; }
                        when "!>!" { $suffix ~= "\\accent"; }
                        when "+" { $suffix ~= "-+"; }
                        when "!+!" { $suffix ~= "-+"; }
                        when "segno"  { $lilypond ~= '\\mark \\markup { \\musicglyph #"scripts.segno" }'; }
                        when "coda"   { $lilypond ~= '\\mark \\markup { \\musicglyph #"scripts.coda" }'; }
                        when "D.C."   { $lilypond ~= '\\mark "D.C."'; }
                        when "D.S."   { $lilypond ~= '\\mark "D.S."'; }
                        # when "D.C."   { $suffix ~= '^\\markup { \\bold "  D.C." } '; }
                        # when "D.S."   { $suffix ~= '^\\markup { \\bold "  D.S." } '; }
                        when "fine"   { $suffix ~= '^\\markup { \\center-align { Fine } } '; }
                        when "breath" { $lilypond ~= '\\breathe'; }
                        when "crescendo(" | "<("  { $suffix ~= "\\<"; }
                        when "crescendo)" | "<)"  { $suffix ~= "\\!"; }
                        when "diminuendo(" | ">(" { $suffix ~= "\\>"; }
                        when "diminuendo)" | ">)" { $suffix ~= "\\!"; }
                        when /^p+$/ | "mp" | "mf" | /^f+$/ | "fermata" | "accent" | "trill" | "sfz" | "marcato"
                                 { $suffix ~= "\\" ~ $element.value; }
                        when "tenuto" { $suffix ~= "--"; }
                        $*ERR.say: "Unrecognized gracing: " ~ $element.value.perl;
                        %unrecognized_gracings{~$element.value} = 1;
                    }
                }
                when "barline" {
                    $notes ~= self.WrapBar($lilypond, $duration,
                                           :might-be-parital($first-bar && $first-bar-might-need-partial));
                    $first-bar = False;
                    
                    my $need-special = $next-section-is-repeated;
                    if $need-special && $i + 1 < @elements 
                       && @elements[$i+1..*-1].grep({ !token-is-space($_) }) {
                           $need-special = False;
                    }
                    
                    given $element.value {
                        when "||" { $notes ~= $need-special ?? ' \\bar ".|:-||"' !! ' \\bar "||"'; }
                        when "|]" { $notes ~= $need-special ?? ' \\bar ".|:-|."' !! ' \\bar "|."'; }
                        default   { 
                            # $notes ~= ' \\bar "|"'; # this should be automatic -- except when this is wrong!!
                        }
                    }
                    $notes ~= "\n";
                    $lilypond = "";
                    $duration = 0;
                    $.context.bar-line;
                }
                when "inline_field" {
                    given $element.value.key {
                        when "K" { 
                            $!context = LilypondContext.new($element.value.value, 
                                                            $!context.context.meter, 
                                                            $!context.context.length,
                                                            :current-key-info($!context.context.key-info)); 
                            $lilypond ~= $!context.key-to-string;
                            $lilypond ~= $!context.clef-to-string;
                        }
                        when "M" {
                            $!context = LilypondContext.new($!context.context.key-name,
                                                            $element.value.value,
                                                            $!context.context.length);
                            $lilypond ~= $!context.meter-to-string;
                        }
                        when "L" {
                            $!context = LilypondContext.new($!context.context.key-name,
                                                            $!context.context.meter,
                                                            $element.value.value);
                        }
                    }
                }
                when "slur_begin" {
                    $suffix ~= "(";
                    $in-slur = True;
                }
                when "slur_end" {
                    $lilypond .= subst(/(\s+)$/, { ")$_" }) if $in-slur;
                    $*ERR.say: "Warning: End-slur found without begin-slur" unless $in-slur;
                    $in-slur = False;
                }
                when "multi_measure_rest" {
                    $lilypond ~= "\\compressFullBarRests R"
                               ~ $!context.get-Lilypond-measure-length
                               ~ "*"
                               ~ $element.value.measures_rest ~ " ";
                }
                when "chord_or_text" {
                    for @($element.value) -> $chord_or_text {
                        if $chord_or_text ~~ ABC::Chord {
                            $suffix ~= '^' ~ $chord_or_text ~ " ";
                        } else {
                            given $element.value {
                                when /^ '^'(.*)/ { $suffix ~= '^"' ~ $0 ~ '" ' }
                            }
                        }
                    }
                }
                when "grace_notes" {
                    $*ERR.say: "Unused suffix in grace note code: $suffix" if $suffix;
                    
                    $lilypond ~= $element.value.acciaccatura ?? "\\acciaccatura \{" !! "\\grace \{";
                    if $element.value.notes == 1 {
                        $lilypond ~= self.StemToLilypond($element.value.notes[0], ""); 
                    } else {
                        $lilypond ~= self.StemToLilypond($element.value.notes[0], "[");
                        for 1..^($element.value.notes - 1) {
                            $lilypond ~= self.StemToLilypond($element.value.notes[$_], "");
                        }
                        $lilypond ~= self.StemToLilypond($element.value.notes[*-1], "]");
                    }
                    $lilypond ~= " \} ";
                    
                    $suffix = "";
                }
                when "spacing" { $lilypond ~= $spacing-comment }
                when "endline" { $lilypond ~= "\\break \\noPageBreak" if $use-ABC-line-breaks; }
                # .say;
            }
        }
    
        $out.say: "\{";
        $notes ~= self.WrapBar($lilypond, $duration,
                               :might-be-parital($first-bar && $first-bar-might-need-partial));
        $first-bar = False;
        $out.say: $notes;
        $out.say: " \}";
    }
    
    method BodyToLilypond(@elements, $out, :$prefix?) {
        $out.say: "\{";
        $out.say: $prefix if $prefix;

        # if tune contains M: none sections, turn off barnumber display
        if @elements.grep({ $_.key eq "inline_field" && $_.value.key eq "M" && $_.value.value eq "none" }) {
            $out.say: "\\override Score.BarNumber.break-visibility = ##(#f #f #f)";
        }

        $out.print: $.context.key-to-string;
        $out.say: "\\accidentalStyle modern-cautionary";
        $out.print: $.context.clef-to-string;
        $out.print: $.context.meter-to-string;
        
        sub element-to-marker($element) {
            given $element.key {
                when "nth_repeat" { $element.value; }
                when "barline" {
                    if $element.value ne "|" {
                        $element.value;
                    } else {
                        "";
                    }
                }
                default { ""; }
            }
        }
        
        my $outer-self = self;
        
        class SectionInfo {
            has $.start-index;
            has $.end-index;
            
            method is-ending { @elements[self.start-index].key eq "nth_repeat"; }

            method is-space { 
                @elements[self.start-index..self.end-index].grep({ token-is-space($_) })
                    == @elements[self.start-index..self.end-index] 
            }

            method starts-with-repeat {
                so element-to-marker(@elements[self.start-index]) eq "|:" | "::" | ":|:";
            }
            method ends-with-repeat {
                so element-to-marker(@elements[self.end-index]) eq ":|" | "::" | ":|:";
            }

            method total-duration {
                [+] (self.start-index..self.end-index).map(-> $i { $outer-self.Duration(@elements[$i])});
            }

            method first-bar-duration {
                my $i = self.starts-with-repeat ?? self.start-index + 1 !! self.start-index;
                my $duration = 0;
                while $i < +@elements {
                    last if @elements[$i].key eq "barline";
                    $duration += $outer-self.Duration(@elements[$i++]);
                }
                $duration;
            }
        }
        
        sub sections-to-lilypond(@sections, :$next-section-is-repeated?, :$first-bar-might-need-partial?) {
            my $start = @sections[0].start-index;
            $.log.say: "start = $start, +elements = { +@elements }";
            ++$start if @elements[$start].key eq "barline";
            $.log.say: "outputing $start to {@sections[*-1].end-index} { $next-section-is-repeated ?? 'Next section repeated' !! '' }";
            self.SectionToLilypond(@elements[$start .. @sections[*-1].end-index], 
                                   $out, :$next-section-is-repeated, :$first-bar-might-need-partial);
        }

        my $start-of-section = 0;
        my @sections;
        for @elements.kv -> $i, $element {
            next if $i == $start-of-section;
            given element-to-marker($element) {
                when /\d/ {
                    @sections.push(SectionInfo.new(start-index => $start-of-section,
                                                   end-index => $i-1));
                    $start-of-section = $i;
                }
                when '|:' {
                    @sections.push(SectionInfo.new(start-index => $start-of-section,
                                                   end-index => $i-1));
                    $start-of-section = $i;
                }                
                when '::' | ':|:' { 
                    @sections.push(SectionInfo.new(start-index => $start-of-section,
                                                   end-index => $i));
                    $start-of-section = $i;
                }                
                when '|]' | '||' | ':|' { 
                    @sections.push(SectionInfo.new(start-index => $start-of-section,
                                                   end-index => $i));
                    $start-of-section = $i+1;
                }                
            }
        }
        @sections.push(SectionInfo.new(start-index => $start-of-section,
                                       end-index => @elements - 1));

        write-sections(@sections);

        sub write-section($section) {
            $.log.say: "{$section.start-index} => {$section.end-index}" 
                       ~ " {@elements[$section.start-index]} / {@elements[$section.end-index]}"
                       ~ " {$section.is-space ?? "SPACING" !! ""}";
        }

        sub write-sections(@sections) {
            for @sections -> $section {
                write-section($section);
            }
        }

        sub output-sections(@sections, :$next-section-is-repeated?, :$first-bar-might-need-partial?) {
            $.log.say: "******************************** start cluster of sections";
            write-sections(@sections);
            return unless @sections;
            my @endings;
            for @sections.kv -> $i, $section {
                @endings.push($i) if $section.is-ending;
            }
            if @endings {
                my $volta-count = 2;
                # SHOULD: use endings to figure out right volta count
                $out.print: "\\repeat volta $volta-count ";
                sections-to-lilypond(@sections[0..^@endings[0]], :$next-section-is-repeated,
                                     :$first-bar-might-need-partial);
                $out.say: "\\alternative \{";
                for @endings.rotor(2=>-1) -> ($a, $b) {
                    $.log.say: "ending is $a => $b";
                    sections-to-lilypond(@sections[$a..^$b], :$next-section-is-repeated);
                }
                sections-to-lilypond(@sections[@endings[*-1]..(*-1)], :$next-section-is-repeated);
                $out.say: "\}";
            } elsif @sections.grep(*.ends-with-repeat) {
                $out.print: "\\repeat volta 2 ";
                sections-to-lilypond(@sections, :$next-section-is-repeated,
                                     :$first-bar-might-need-partial);
            } else {
                sections-to-lilypond(@sections, :$next-section-is-repeated,
                                     :$first-bar-might-need-partial);
            }
        }

        my $first-bar-might-need-partial = @sections
                                           && 0 < @sections[0].first-bar-duration < $.context.ticks-in-measure;
        if $first-bar-might-need-partial && +@sections > 1 {
            if @sections[0].total-duration + @sections[1].first-bar-duration == $.context.ticks-in-measure {
                $first-bar-might-need-partial = False;
            }
        }

        # delete empty sections from the end of the tune
        while @sections && @sections[*-1].is-space {
            @sections.pop;
        }

        my $in-endings = False;
        my @section-cluster;
        for @sections -> $section {
            if $in-endings {
                if $section.is-ending || $section.is-space {
                    @section-cluster.push($section);
                } else {
                    output-sections(@section-cluster,
                                    :next-section-is-repeated($section.starts-with-repeat),
                                    :$first-bar-might-need-partial);
                    $first-bar-might-need-partial = False;
                    @section-cluster = ();
                    @section-cluster.push($section);
                    $in-endings = False;
                }
            } else {
                if @section-cluster && $section.starts-with-repeat {
                    # output everything up to the current section
                    output-sections(@section-cluster, :next-section-is-repeated(True),
                                    :$first-bar-might-need-partial);
                    $first-bar-might-need-partial = False;
                    @section-cluster = ();
                } 

                @section-cluster.push($section);
            }

            if !$in-endings {
                if $section.is-ending {
                    $in-endings = True;
                } else {
                    if $section.ends-with-repeat {
                        output-sections(@section-cluster, :next-section-is-repeated(True),
                                        :$first-bar-might-need-partial);
                        $first-bar-might-need-partial = False;
                        @section-cluster = ();
                    }
                }
            }
        }
        if @section-cluster {
            output-sections(@section-cluster, :$first-bar-might-need-partial);
            $first-bar-might-need-partial = False;
        }
    
        $out.say: "\}";
    }
    
}

sub TuneBodyToLilypondStream($tune, $out, :$prefix?, :$log?) is export {
    my $key = $tune.header.get-first-value("K");
    my $meter = $tune.header.get-first-value("M");
    my $length = $tune.header.get-first-value("L") // default-length-from-meter($meter);
    my $convertor = TuneConvertor.new($key, $meter, $length, $log // (open :w, $*SPEC.devnull));
    $convertor.BodyToLilypond($tune.music, $out, :$prefix);
}

sub HeaderToLilypond(ABC::Header $header, $out, :$title?, :$subtitle?) is export {
    $out.say: "\\header \{";

    my $working-title = $title // $header.get-first-value("T") // "Unworking-titled";

    my @skips = %title-skips.keys;
    $working-title.=subst(/ (@skips) /, "", :global);

    $working-title = sanitize-quotation-marks($working-title);
    $out.say: "    title = \" $working-title \"";
    my $composer = sanitize-quotation-marks(get-field-if-there($header, "C"));
    my $origin = sanitize-quotation-marks(get-field-if-there($header, "O"));
    if $origin {
        if $origin ~~ m:i/^for/ {
            $out.say: qq/    dedication = "$origin"/;
        } else {
            if $composer {
                $composer ~= " ($origin)";
            } else {
                $composer = $origin;
            }
        }
    }
    $out.say: qq/    composer = "{ sanitize-quotation-marks($composer) }"/ if $composer;
    if $subtitle {
        $out.say: "    subtitle = " ~ '"' ~ $subtitle ~ '"';
    } else {
        $out.say: "    subtitle = ##f";
    }

    $out.say: "}";
}

sub tune-to-score($tune, $out, $log, @notes = $tune.header.get("N").map(*.value), :$subtitle?) is export {
    $*ERR.say: "Working on { $tune.header.get-first-value("T") // $tune.header.get-first-value("X") }";
    $log.say: "Working on { $tune.header.get-first-value("T") // $tune.header.get-first-value("X") }";
    $out.say: "\\score \{";

        TuneBodyToLilypondStream($tune, $out, :$log);
        HeaderToLilypond($tune.header, $out, :$subtitle);

    $out.say: "}\n\n";
    
    if @notes {
        for @notes -> $note {
            next if $note ~~ / ^ \s* $ /;
            
            $out.say: q:to/END/;
                \noPageBreak
                \markup \fill-line {
                    \center-column \wordwrap-lines {
                END
                
            $out.say: "        " ~ sanitize-quotation-marks($note, :escape-number-sign);

            $out.say: q:to/END/;
                    }
                }
                
                END
        }
    } else {
        # This was to allow breaks between tunes even if the tune
        # ended with a linebreak and didn't have a note.  Now
        # trying to just avoid ending on a linebreak!

        # $out.say: q:to/END/;
        #     \markup \fill-line { }
        #     END
    }
}

sub GetUnrecognizedGracings() is export {
    %unrecognized_gracings
}

sub add-substitute($look-for, $replace-with) is export {
    %substitutes{$look-for} = $replace-with;
}

sub add-title-skip($look-for) is export {
    %title-skips{$look-for} = 1;
}

