#!/usr/bin/perl

#
# pg2mysql transforms a pgdump file on STDIN into a MySQL dump file on
# STDOUT. Dump format must be INSERT statements, not binary or COPY
# statements.
#
# Usage:
# ./pg2mysql < file.pgdump > mysql.sql
# ./pg2mysql --skip table1 --skip table2 --insert_ignore < file.pgdump > mysql.sql 2>warnings.txt
#
# It's heavily inspired by this php script:
# https://github.com/ChrisLundquist/pg2mysql
# Which in turn was adapated from this web form:
# http://www.lightbox.ca/pg2mysql.php
#
# It handles:
# * CREATE TABLE statements, types converted to MySQL equivalents
# * INSERT INTO statements, some values (like timestamp strings)
#   massaged to work with MySQL
# * CREATE INDEX statements
# * ALTER TABLE statements (for foreign keys, other constraints)
# * With --insert_ignore, uses INSERT IGNORE statements to be more
#   lenient with non-confirming values (at the cost to import
#   accuracy)
#
# Sequences are not created, but any sequences set as the default on a
# column are converted to an AUTO_INCREMENT on that column.
#
# It has a lot of limitations and there are surely bugs. If you find
# some, tell us. But these are the things we know about:
# 
# * Many types badly / not supported
# * Will convert a character varying type to longtext if no length is
#   specified, which means MySQL won't be able to make it a key
# * Other schema entities like triggers and views are not created

use warnings;
use strict;

use Getopt::Long;

my @skip_tables;
my $insert_ignore;
my $strict;
GetOptions (
    "skip=s" => \@skip_tables,
    "insert_ignore" => \$insert_ignore,
    "strict" => \$strict
    );

$| = 1;

print "--\n";
print "-- Generated by pg2mysql\n";
print "--\n";

print "set foreign_key_checks = off;\n";

my $in_begin_end = 0;

my $in_create    = 0;
my $in_alter     = 0;
my $in_insert    = 0;

my $skip         = 0;
my $debug        = 0;
my %dbs;
my @deferred_ai_statements;

# We need one line of lookahead for some of these transformations
my $line;
my $nextline;

while (<>) {
    $line = $nextline;
        
    chomp;
    $nextline = $_;

    handle_line($line, $nextline);
}

$line = $nextline;
$nextline = "";

handle_line($line, $nextline);

foreach my $deferred ( @deferred_ai_statements ) {
    print "$deferred\n";
}

sub handle_line {
    my $line = shift || "";
    my $nextline = shift;

    # Explicitly die when we encounter lines we can't handle
    if ( $strict ) {
	if ( $line =~ /CREATE TYPE / ) {
	    die "CREATE TYPE statements not supported";
	}
    }
    
    # Explicitly skipped statments need to be defined first.
    if ( $in_begin_end || $line =~ m/^\s*begin\s*$/i) {
        ($line, $in_begin_end, $skip) = handle_begin_end($line);
    } elsif ( $line =~ m/pg_catalog\.setval/ ) {
	$line = handle_setval($line);
    } elsif ( $in_create || $line =~ m/^\s*CREATE TABLE/ ) {
        ($line, $in_create, $skip) = handle_create($line);
    } elsif ( $in_alter || $line =~ m/^\s*ALTER TABLE/ ) {
        ($line, $in_alter, $skip) = handle_alter($line, $nextline);
    } elsif ( $in_insert || $line =~ m/^\s*INSERT INTO/ ) {
        ($line, $in_insert, $skip) = handle_insert($line, $nextline);
    } elsif ( $line =~ m/^\s*CREATE (UNIQUE )?INDEX/ ) {
        ($line, $skip) = handle_create_index($line);
    } else {
        print_warning("$line");
        return;
    }

    print "$line\n" unless $skip;
}

sub handle_create {
    my $line = shift;

    if ( $line =~ m/^\s*CREATE TABLE (\S+)/ ) {
        # pgdump doesn't include "create database" statements for any
        # schemas being exported, so we need to emit them here the
        # first time we see a schema
        my ($schema, $table) = split /\./, $1;
        if ( !$dbs{$schema} ) {
            print "DROP DATABASE IF EXISTS $schema;\n";
            print "CREATE DATABASE $schema;\n";
            $dbs{$schema} = 1;
        }
        
        if ( grep { $1 eq $_ } @skip_tables ) {
            print_warning("skipping table $1");
            $skip = 1;
        } else {
            $skip = 0;
        }
    }
    
    debug_print("input line is $line\n");

    if ( $line =~ m/\s*CONSTRAINT .*? CHECK/ ) {
        $line = handle_check($line);
        return ($line, 1, 0);
    }
    
    # Some notes on these conversions:
    # 
    # Array types are not supported in mysql, but for arrays of
    # strings, we can fake it because the insert statement looks like
    # '{value1,value2}'
    #
    # Some types can't be supported so are just left alone to fail in
    # mysql, including: tsvector

    no warnings qw/uninitialized/;
    $line =~ s/ int_unsigned/ integer UNSIGNED/;
    $line =~ s/ smallint_unsigned/ smallint UNSIGNED/;
    $line =~ s/ bigint_unsigned/ bigint UNSIGNED/;
    $line =~ s/ serial / integer auto_increment /;
    $line =~ s/ uuid/ varchar(36)/;
    $line =~ s/ bytea/ BLOB/;
    $line =~ s/ boolean/ bool/;
    $line =~ s/ jsonb/ json/; # same as json in mysql
    $line =~ s/ bool DEFAULT true/ bool DEFAULT 1/;
    $line =~ s/ bool DEFAULT false/ bool DEFAULT 0/;
    $line =~ s/ `text\[\]`/ longtext/;
    $line =~ s/ text\[\]/ longtext/;
    $line =~ s/ `text`/ longtext/;
    $line =~ s/ text/ longtext/;
    $line =~ s/ character varying\(([0-9]*)\)\[\]/ longtext/;
    $line =~ s/ character varying\[\]/ longtext/;
    $line =~ s/ character \(([0-9]*)\)\[\]/ longtext/;
    $line =~ s/ character\[\]/ longtext/;
    $line =~ s/ character varying\(([0-9]*)\)/ varchar($1)/;
    $line =~ s/ character varying/ longtext/;
    $line =~ s/ character\s*\(([0-9]*)\)/ char($1)/;
    $line =~ s/ character/ longtext/;
    $line =~ s/ DEFAULT \('([0-9]*)'::int[^ ,]*/ DEFAULT $1/;
    $line =~ s/ DEFAULT \('([0-9]*)'::smallint[^ ,]*/ DEFAULT $1/;
    $line =~ s/ DEFAULT \('([0-9]*)'::bigint[^ ,]*/ DEFAULT $1/;
    # strip off sequence defaults, can't be converted to
    # auto_increment here (only via ALTER TABLE statement). Not clear
    # what pg_dump setting does it this way instead of after the data
    # section.
    $line =~ s/ DEFAULT nextval\(.*\)/ /; 
    $line =~ s/::.*,/,/; # strip extra type info
    $line =~ s/::[^,]*$//; # strip extra type info
    $line =~ s/ time(\([0-6]\))? with time zone/ time$1/;
    $line =~ s/ time(\([0-6]\))? without time zone/ time$1/;
    $line =~ s/ timestamp(\([0-6]\))? with time zone/ timestamp$1/;
    $line =~ s/ timestamp(\([0-6]\))? without time zone/ timestamp$1/;
    $line =~ s/ timestamp(\([0-6]\))? DEFAULT '(.*)(\+|\-).*'/ timestamp$1 DEFAULT '%1'/; # strip timezone in defaults
    $line =~ s/ timestamp(\([0-6]\))? DEFAULT now()/ timestamp$1 DEFAULT CURRENT_TIMESTAMP/;
    $line =~ s/ timestamp NOT NULL/ timestamp DEFAULT 0${1}${2}/;

    $line =~ s/ cidr/ varchar\(32\)/;
    $line =~ s/ inet/ varchar\(32\)/;
    $line =~ s/ macaddr/ varchar\(32\)/;

    $line =~ s/ money/ varchar\(32\)/;

    $line =~ s/ longtext DEFAULT [^,]*( NOT NULL)?/ longtext $1/; # text types can't have defaults in mysql
    $line =~ s/ DEFAULT .*\(\)//; # strip function defaults
    # lots of these function translations are missing
    $line =~ s/ DEFAULT json_build_object\((.*)\)/ DEFAULT json_object($1)/;

    # extension types, usually prefixed with the name of a schema
    $line =~ s/ \S*\.citext/ text/;

    my $field_def = ( $line !~ m/^CREATE/ && $line !~ m/^\s*CONSTRAINT/ && $line !~ m/\s*PRIMARY KEY/ && $line !~ m/^\s*\);/ );
    
    # backtick quote any field name as necessary
    # TODO: backtick field names in constraints as well
    if ( $field_def && $line !~ m/^\s*`(.*?)` / ) {
        $line =~ m/^\s*(.*?) /;
        my $col = $1;
        $line =~ s/$col/`$col`/;
    }
            
    my $statement_continues = 1;
    if ( $line =~ m/\);$/ ) {
        $statement_continues = 0;
    }

    debug_print("in create, cont = $statement_continues\n");
    
    return ($line, $statement_continues, $skip);
}

sub handle_check {
    my $line = shift;

    # For check constraints, we can do a couple useful things:
    # 1) Strip off type conversions, which won't parse
    # 2) Convert ANY syntax into IN syntax (common check constraint in pg)

    # First strip off type conversions, which can be parenthesized.
    while ( $line =~ s/\(([^\)]+)\)::[\w ]+/$1/g ) {}
    while ( $line =~ s/(\(([^\)]+))\)::[\w ]+/$1/g ) {}
    $line =~ s/::[\w ]+//g;

    # Then translate an ANY check into an IN check
    $line =~ s/= ANY \((ARRAY\[(.*?)\]\))/= ANY $1/;
    $line =~ s/= ANY ARRAY\[(.*?)\]/ IN ($1)/;

    # We may end up with one extra set of parentheses here, remove them if so
    $line =~ s/ IN \(\((.*?)\)\)/ IN ($1)/;

    # Final sanity check: make sure that there isn't an extra right
    # paren (can happen due to perl's regex matching rules from
    # regexes above)
    my $left_parens = () = $line =~ m/\(/g;
    my $right_parens = () = $line =~ m/\)/g;
    while ( $right_parens > $left_parens ) {
        $line =~ s/\)(,)?\s*$/$1/;
        $right_parens -= 1;
    }
    
    return $line;
}

sub handle_alter {
    my $line = shift;
    my $nextline = shift;

    if ( $line =~ m/ALTER TABLE .* OWNER TO/ ) {
        return ($line, 0, 1);
    }
    
    $line =~ s/ALTER TABLE ONLY/ALTER TABLE/;
    $line =~ s/DEFERRABLE INITIALLY DEFERRED//;
    $line =~ s/USING \S+;/;/;

    if ( $line =~ m/^\s*ALTER TABLE (\S+)/ ) {
        if ( grep { $1 eq $_ } @skip_tables ) {
            print_warning("skipping table $1");
            $skip = 1;
        } else {
            $skip = 0;
        }
    }

    # We can't put a foreign key constraint onto a table that we skipped
    if ( $nextline =~ m/\s*ADD CONSTRAINT .*? FOREIGN KEY .*? REFERENCES ([^\(]+)/ ) {
        if ( grep { $1 eq $_ } @skip_tables ) {
            print_warning("skipping foreign key on skipped table $1");
            $skip = 1;
        }
    }
    
    debug_print("alter line is $line\n");

    # Escape field names in unique and primary key constraints
    if ( $line =~ m/^\s*ADD CONSTRAINT (\S+) UNIQUE \(([^\)]*)\);/ ) {
        my @cols = split /\s*,\s*/, $2;
        my @quoted = map { "`$_`" } @cols;
        my $joined = join ",", @quoted;
        $line = "ADD CONSTRAINT $1 UNIQUE ($joined);";
    }

    if ( $line =~ m/^\s*ADD CONSTRAINT (\S+) PRIMARY KEY \(([^\)]*)\);/ ) {
        my @cols = split /\s*,\s*/, $2;
        my @quoted = map { "`$_`" } @cols;
        my $joined = join ",", @quoted;
        $line = "ADD CONSTRAINT $1 PRIMARY KEY ($joined);";
    }
    
    my $statement_continues = 1;
    if ( $line =~ m/\;$/ ) {
        $statement_continues = 0;
    } elsif ( $line =~ m/FOREIGN KEY.*\s*;$/ ) { # foreign key alters add a space before the semicolon
        $statement_continues = 0;
    }

    # For tables with a sequence for an ID, pg_dump does the following:
    # 1) create the table with no keys
    # 2) create a sequence for that table
    # 3) alter table to set the default to that sequence nextval
    # 4) inserts
    # 5) alter table to add primary key
    #
    # This doesn't work in mysql. 2) and 3) are not supported at all,
    # and a column can't be set to auto_increment unless it's a key in
    # the table. So instead, when we see this pattern, we defer
    # auto_increment changes until after the primary key changes. This
    # also makes assumptions about the type of a primary key column
    # which may not be accurate.  
    #
    # ALTER TABLE public.account_emailaddress ALTER COLUMN id SET DEFAULT nextval

    if ( $line =~ m/\s*ALTER TABLE (\S+) ALTER COLUMN (\S+) SET DEFAULT nextval/i ) {
        unless ( grep { $1 eq $_ } @skip_tables ) {
            push @deferred_ai_statements, "ALTER TABLE $1 MODIFY `$2` integer auto_increment;";
            $line = "";
        }
    }
    
    return ($line, $statement_continues, $skip);
}

sub handle_insert {
    my $line = shift;
    my $nextline = shift;

    if ( $line =~ m/^\s*INSERT INTO (\S+)/ ) {
        if ( grep { $1 eq $_ } @skip_tables ) {
            print_warning("skipping table $1");
            $skip = 1;
        } else {
            $skip = 0;
        }

        # Escape any field names, some of which will not parse in MySQL (e.g. `key`)

        $line =~ /^\s*INSERT INTO (\S+)\s*\(([^\)]+)\)/i;
        my @fields = split /\s*,\s*/, $2 if $2;
        my $escaped = join(',', map { backtick($_) } @fields);
        
        $line =~ s/^\s*INSERT INTO (\S+)\s*\(([^\)]+)\)/INSERT INTO $1 \($escaped\)/;

        if ( $insert_ignore ) {
            $line =~ s/^\s*INSERT INTO /INSERT IGNORE INTO /;
        }
    }

    # timestamp literal strings need timezones stripped
    # 2020-06-08 11:27:31.597687-07
    $line =~ s/'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6})(-|\+)\d{2}'/'$1'/g;
    
    $line =~ s/\\([nt])/\\\\$1/g; # tab and newline literals, need an additional escape (for JSON strings)

    # Change hex characters to proper format for MySQL
    $line =~ s/'\\x(\S*)'/X'$1'/g;
    
    # Count single quotes
    my $quotes = () = $line =~ m/'/g;
    
    # Escaped quote characters, this is an odd feature of pgdump.
    # An escaped single quote escapes, so does '', but if you use both (\'') they cancel each other out.
    # Same thing is true in JSON strings (double quoted).
    # No idea why pgdump behaves this way, seems like a bug.
    $line =~ s/\\''/\\\\''/g; 
    $line =~ s/\\"/\\\\"/g; # escaped double quote characters

    my $statement_continues = 1;
    if ( $line =~ m/\);$/ ) {
        # the above is a reasonable heuristic for a line not
        # continuing but isn't fool proof, and can fail on long text
        # lines that end in );. To do slightly better, we also keep
        # track of how many single quotes we've seen

	warn "line $. ended, num quotes is $quotes and in_insert is $in_insert\n";

        if ( (!$in_insert && $quotes % 2 == 0)
             || ($in_insert && $quotes % 2 == 1) ) {
            warn "marking statement ended";
            $statement_continues = 0;
        }
    }

    return ($line, $statement_continues, $skip);
}

sub handle_create_index {
    my $line = shift;

    # CREATE INDEX account_emailaddress_email_03be32b2_like ON public.account_emailaddress USING btree (email varchar_pattern_ops);
    $line =~ s/ USING btree//;
    $line =~ s/ varchar_pattern_ops//;
    
    $line =~ m/CREATE (UNIQUE )?INDEX (\S+) ON (\S+)\s*\(([^\(]+)\)/;
    if ( $3 ) {
        if ( grep { $3 eq $_ } @skip_tables ) {
            return ($line, 1);
        }
    }

    # TODO: backtick column names in index
    return ($line, 0);
}

sub handle_begin_end {
    my $line     = shift;
    my $in_begin = shift;
    my $skip     = shift;

    # Ignore everything in these blocks. The parser can get confused if there
    # are INSERT statements in the functions.
    $in_begin = 1;
    $skip = 1;
    if ( $line =~ /^\s*end.*;?\s*$/i ) {
        $in_begin = 0;
    }

    return ($line, $in_begin, $skip);
}

# Postgres will output a select if it needs to set an auto increment value
# of the form:
# SELECT pg_catalog.setval('public.my_table_id_seq', 33, true);
# This must be parsed and converted to:
# ALTER TABLE my_table AUTO_INCREMENT = value;
sub handle_setval {
    my $line = shift;

    my ($table, $value) = ("", "");
    $line =~ /select pg_catalog\.setval\('(public\.\w+)_\w+_seq',\s+(\d+)/i;
    die "Can't parse select" unless ($1 and $2);
    $table = $1;
    $value = $2;
    $line = "ALTER TABLE $table AUTO_INCREMENT = $value;";
    return ($line);
}

sub backtick {
    my $s = shift;
    return '`' . $s . '`';
}
    
sub ids {
    my $s = shift;
    $s =~ s/"/`/g;
    return $s;
}

sub debug_print {
    my $msg = shift;
    print $msg if $debug;
}   

sub print_warning {
    my $msg = shift;
    # TODO: would be better to emit these as comments, but putting
    # these in the SQL file causes problems for the dolt batch parser
    # (doesn't understand comments with semicolons)
    warn "-- $msg\n";
}
