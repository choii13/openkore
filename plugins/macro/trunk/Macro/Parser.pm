# $Id: Parser.pm 6340 2008-04-29 18:43:27Z lastclick $
package Macro::Parser;

use strict;
use encoding 'utf8';

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(parseMacroFile parseCmd);

use Globals;
use List::Util qw(max min sum);
use Log qw(message warning error);
use Text::Balanced qw/extract_bracketed/;
use Macro::Data;
use Macro::Utilities qw(refreshGlobal getnpcID getItemIDs getItemPrice getStorageIDs getInventoryIDs
	getPlayerID getVenderID getRandom getRandomRange getInventoryAmount getCartAmount getShopAmount
	getStorageAmount getVendAmount getConfig getWord q4rx getArgFromList getListLenght);

our ($rev) = q$Revision: 6340 $ =~ /(\d+)/;

# adapted config file parser
sub parseMacroFile {
	my ($file, $no_undef) = @_;
	unless ($no_undef) {
		undef %macro;
		undef %automacro
	}

	my %block;
	my $tempmacro = 0;
	open FILE, "<:utf8", $file or return 0;
	foreach (<FILE>) {
		s/^\s*#.*$//;      # remove comments
		s/^\s*//;          # remove leading whitespaces
		s/\s*[\r\n]?$//g;  # remove trailing whitespaces and eol
		s/  +/ /g;         # trim down spaces
		next unless ($_);

		if (!%block && /{$/) {
			my ($key, $value) = $_ =~ /^(.*?)\s+(.*?)\s*{$/;
			if ($key eq 'macro') {
				%block = (name => $value, type => "macro");
				$macro{$value} = []
			} elsif ($key eq 'automacro') {
				%block = (name => $value, type => "auto")
			} else {
				%block = (type => "bogus");
				warning "$file: ignoring line '$_' (munch, munch, strange block)\n"
			}
			next
		}

		if (%block && $block{type} eq "macro") {
			if ($_ eq "}") {
				undef %block
			} else {
				push(@{$macro{$block{name}}}, $_)
			}
			next
		}

		if (%block && $block{type} eq "auto") {
			if ($_ eq "}") {
				if ($block{loadmacro}) {
					undef $block{loadmacro}
				} else {
					undef %block
				}
			} elsif ($_ eq "call {") {
				$block{loadmacro} = 1;
				$block{loadmacro_name} = "tempMacro".$tempmacro++;
				$automacro{$block{name}}->{call} = $block{loadmacro_name};
				$macro{$block{loadmacro_name}} = []
			} elsif ($block{loadmacro}) {
				push(@{$macro{$block{loadmacro_name}}}, $_)
			} else {
				my ($key, $value) = $_ =~ /^(.*?)\s+(.*)/;
				unless (defined $key) {
					warning "$file: ignoring '$_' (munch, munch, not a pair)\n";
					next
				}
				if ($amSingle{$key}) {
					$automacro{$block{name}}->{$key} = $value
				} elsif ($amMulti{$key}) {
					push(@{$automacro{$block{name}}->{$key}}, $value)
				} else {
					warning "$file: ignoring '$_' (munch, munch, unknown automacro keyword)\n"
				}
			}
			next
		}
		
		if (%block && $block{type} eq "bogus") {
			if ($_ eq "}") {undef %block}
			next
		}

		my ($key, $value) = $_ =~ /^(.*?)\s+(.*)/;
		unless (defined $key) {
			warning "$file: ignoring '$_' (munch, munch, strange food)\n";
			next
		}

		if ($key eq "!include") {
			my $f = $value;
			if (!File::Spec->file_name_is_absolute($value) && $value !~ /^\//) {
				if ($file =~ /[\/\\]/) {
					$f = $file;
					$f =~ s/(.*)[\/\\].*/$1/;
					$f = File::Spec->catfile($f, $value)
				} else {
					$f = $value
				}
			}
			if (-f $f) {
				my $ret = parseMacroFile($f, 1);
				return $ret unless $ret
			} else {
				error "$file: Include file not found: $f\n";
				return 0
			}
		}
	}
	close FILE;
	return 0 if %block;
	return 1
}

# parses a text for keywords and returns keyword + argument as array
# should be an adequate workaround for the parser bug
#sub parseKw {
#	my @pair = $_[0] =~ /\@($macroKeywords)\s*\(\s*(.*)\s*\)/i;
#	return unless @pair;
#	if ($pair[0] eq 'arg') {
#		return $_[0] =~ /\@(arg)\s*\(\s*(".*?",\s*\d+)\s*\)/
#	} elsif ($pair[0] eq 'random') {
#		return $_[0] =~ /\@(random)\s*\(\s*(".*?")\s*\)/
#	}
#	while ($pair[1] =~ /\@($macroKeywords)\s*\(/) {
#		@pair = $pair[1] =~ /\@($macroKeywords)\s*\((.*)/
#	}
#	return @pair
#}

sub parseKw {
	my @full = $_[0] =~ /@($macroKeywords)s*((s*(.*?)s*).*)$/i;
	my @pair = ($full[0]);
	my ($bracketed) = extract_bracketed ($full[1], '()');
	return unless $bracketed;
	push @pair, substr ($bracketed, 1, -1);

	return unless @pair;
	if ($pair[0] eq 'arg') {
		return $_[0] =~ /\@(arg)\s*\(\s*(".*?",\s*\d+)\s*\)/
	} elsif ($pair[0] eq 'random') {
		return $_[0] =~ /\@(random)\s*\(\s*(".*?")\s*\)/
	}
	while ($pair[1] =~ /\@($macroKeywords)\s*\(/) {
		@pair = parseKw ($pair[1])
	}
	return @pair
}

# substitute variables
sub subvars {
# should be working now
	my $pre = $_[0];
	my ($var, $tmp);

	# variables
	while (($var) = $pre =~ /(?:^|[^\\])\$(\.?[a-z][a-z\d]*)/i) {
		$tmp = (defined $varStack{$var})?$varStack{$var}:"";
		$var = q4rx $var;
		$pre =~ s/(^|[^\\])\$$var([^a-zA-Z\d]|$)/$1$tmp$2/g;
	}

	# doublevars
	while (($var) = $pre =~ /\$\{(.*?)\}/i) {
		$tmp = (defined $varStack{"#$var"})?$varStack{"#$var"}:"";
		$var = q4rx $var;
		$pre =~ s/\$\{$var\}/$tmp/g
	}

	return $pre
}

# command line parser for macro
# returns undef if something went wrong, else the parsed command or "".
sub parseCmd {
	return "" unless defined $_[0];
	my $cmd = $_[0];
	my ($kw, $arg, $targ, $ret);

	# refresh global vars only once per command line
	refreshGlobal();

	while (($kw, $targ) = parseKw($cmd)) {
		$ret = "_%_";
		# first parse _then_ substitute. slower but more safe
		$arg = subvars($targ);

		if ($kw eq 'npc')           {$ret = getnpcID($arg)}
		elsif ($kw eq 'cart')       {($ret) = getItemIDs($arg, $::cart{'inventory'})}
		elsif ($kw eq 'Cart')       {$ret = join ',', getItemIDs($arg, $::cart{'inventory'})}
		elsif ($kw eq 'inventory')  {($ret) = getInventoryIDs($arg)}
		elsif ($kw eq 'Inventory')  {$ret = join ',', getInventoryIDs($arg)}
		elsif ($kw eq 'store')      {($ret) = getItemIDs($arg, \@::storeList)}
		elsif ($kw eq 'storage')    {($ret) = getStorageIDs($arg)}
		elsif ($kw eq 'Storage')    {$ret = join ',', getStorageIDs($arg)}
		elsif ($kw eq 'player')     {$ret = getPlayerID($arg)}
		elsif ($kw eq 'vender')     {$ret = getVenderID($arg)}
		elsif ($kw eq 'venderitem') {($ret) = getItemIDs($arg, \@::venderItemList)}
		elsif ($kw eq 'venderItem') {$ret = join ',', getItemIDs($arg, \@::venderItemList)}
		elsif ($kw eq 'venderprice'){$ret = getItemPrice($arg, \@::venderItemList)}
		elsif ($kw eq 'venderamount'){$ret = getVendAmount($arg, \@::venderItemList)}
		elsif ($kw eq 'random')     {$ret = getRandom($arg)}
		elsif ($kw eq 'rand')       {$ret = getRandomRange($arg)}
		elsif ($kw eq 'invamount')  {$ret = getInventoryAmount($arg)}
		elsif ($kw eq 'cartamount') {$ret = getCartAmount($arg)}
		elsif ($kw eq 'shopamount') {$ret = getShopAmount($arg)}
		elsif ($kw eq 'storamount') {$ret = getStorageAmount($arg)}
		elsif ($kw eq 'config')     {$ret = getConfig($arg)}
		elsif ($kw eq 'arg')        {$ret = getWord($arg)}
		elsif ($kw eq 'eval')       {$ret = eval($arg)}
		elsif ($kw eq 'listitem')   {$ret = getArgFromList($arg)}
		elsif ($kw eq 'listlenght') {$ret = getListLenght($arg)}
		return unless defined $ret;
		return $cmd if $ret eq '_%_';
		$targ = q4rx $targ;
		$cmd =~ s/\@$kw\s*\(\s*$targ\s*\)/$ret/g
	}

	$cmd = subvars($cmd);
	return $cmd
}

1;