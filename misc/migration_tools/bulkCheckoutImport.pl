#!/usr/bin/perl

use strict;
use warnings;
#use diagnostics;
BEGIN {
    # find Koha's Perl modules
    # test carefully before changing this
    use FindBin;
    eval { require "$FindBin::Bin/../kohalib.pl" };
    eval { use lib $FindBin::Bin; };
}

use open qw( :std :encoding(UTF-8) );
binmode( STDOUT, ":encoding(UTF-8)" );

use Getopt::Long;
use C4::Items;
use C4::Members;

use ConversionTable::ItemnumberConversionTable;
use ConversionTable::BorrowernumberConversionTable;
use Data::Dumper;

binmode( STDOUT, ":encoding(UTF-8)" );
my ( $input_file, $number, $verbose) = ('',0,undef);
my $borrowernumberConversionTable = 'borrowernumberConversionTable';
my $itemnumberConversionTable = 'itemnumberConversionTable';

$|=1;

GetOptions(
    'file:s'                               => \$input_file,
    'b|bnConversionTable:s'                => \$borrowernumberConversionTable,
    'i|inConversionTable:s'                => \$itemnumberConversionTable,
    'n:f'                                  => \$number,
    'verbose'                              => \$verbose,
);

my $help = <<HELP;

perl bulkCheckoutImport.pl --file /home/koha/pielinen/checkouts.migrateme -n 1200 \
    --bnConversionTable borrowernumberConversionTable

Migrates the Perl-serialized MMT-processed patrons-files to Koha.

  --file               The perl-serialized HASH of checkouts.

  -n                   How many checkouts to migrate? Defaults to all.

  --bnConversionTable  From which key-value -file to read the converted borrowernumber.
                       We are adding Patrons to a database with existing Patrons, so we need to convert
                       borrowernumbers so they won't overlap with existing ones.
                       borrowernumberConversionTable has the following format, where first column is the original
                       customer id and the second column is the mapped Koha borrowernumber:

                           1001003 12001003
                           1001004 12001004
                           1001006 12001005
                           1001007 12001006
                           ...

  --inConversionTable  From which file to read the conversion between itemnumber and Item's barcode.
                       File is generated by the bulkItemImport.pl and has the following content:

                           itemnumber:newItemnumber:barcode
                           10001000:1:541N00010001
                           10001001:2:541N00010013
                           10001074:3:541N00010746
                           ...

                       Defaults to 'itemnumberConversionTable'.

HELP

unless ($input_file) {
    die "$help\n\nYou must give the Patrons-file.";
}


my $fh = IO::File->new( $input_file, "<:encoding(utf-8)" );
$borrowernumberConversionTable = ConversionTable::BorrowernumberConversionTable->new($borrowernumberConversionTable, 'read');
$itemnumberConversionTable =     ConversionTable::ItemnumberConversionTable->new($itemnumberConversionTable, 'read');

if ($verbose) {
    print "\nBorrowernumber Conversion Table used:\n";
    foreach my $k (keys %$borrowernumberConversionTable) {
        print $k . " " . $borrowernumberConversionTable->{$k}."\n";
    }
}

my $dbh = C4::Context->dbh;
my $checkoutStatement =
      $dbh->prepare(
            "INSERT INTO issues
                (borrowernumber, itemnumber, issuedate, date_due, branchcode, renewals)
            VALUES (?,?,?,?,?,?)"
      );

sub migrate_checkout {
    my ( $borrowernumber, $itemnumber, $issuedate, $date_due, $branchcode, $renewals) = @_;

    #Make sure the parent biblio exists!
    my $biblionumber = C4::Items::_get_single_item_column('biblionumber', $itemnumber);
    unless (defined $biblionumber) {
        warn "\nCheckout for Item $itemnumber and Patron $borrowernumber has no biblio in Koha!\n";
        return;
    }

    #Make sure the borrowerexists!
    my $testingBorrower = C4::Members::GetMember(borrowernumber => $borrowernumber);
    unless (defined $testingBorrower) {
        warn "\nCheckout for Item $itemnumber has no Patron $borrowernumber in Koha!\n";
        return;
    }


    $checkoutStatement->execute(
        $borrowernumber,      # borrowernumber
        $itemnumber,              # itemnumber
        $issuedate, # issuedate
        $date_due,   # date_due
        $branchcode,    # branchcode
        $renewals,
    );

    C4::Items::ModItem({
              #holdingbranch    => C4::Context->userenv->{'branch'},
              onloan           => $date_due,
            }, $biblionumber , $itemnumber);
}


sub newFromRow {
    no strict 'vars';
    eval shift;
    my $s = $VAR1;
    use strict 'vars';
    warn $@ if $@;
    return $s;
}

my $i = 0;
while (<$fh>) {
    $i++;
    print ".";
    print "\n$i" unless $i % 100;



    my $checkout = newFromRow($_);

    $checkout->{barcode} = $itemnumberConversionTable->fetchBarcode(  $checkout->{itemnumber}  );
    #$checkout->{barcode} is already defined if migrating Libra3.
    unless ($checkout->{barcode}) {
        warn "\nCheckout for itemnumber ".$checkout->{itemnumber}." and Patron ".$checkout->{borrowernumber}." has no Barcode/Item in the itemnumberConversionTable!\n";
        next();
    }
#print "\n\n".Data::Dumper::Dumper($checkout)."\n\n";
    my $itemnumber = C4::Items::GetItemnumberFromBarcode(  $checkout->{barcode}  );
    unless ($itemnumber) {
        warn "\nCheckout for Barcode ".$checkout->{barcode}." and Patron ".$checkout->{borrowernumber}." has no Item in Koha!\n";
        next();
    }
    my $borrowernumber = $borrowernumberConversionTable->fetch(  $checkout->{borrowernumber}  );
    unless ($borrowernumber) {
        warn "\nCheckout for Barcode ".$checkout->{barcode}." and Patron ".$checkout->{borrowernumber}." has no Patron in the borrowernumberConversionTable!\n";
        next();
    }

    migrate_checkout(
                      $borrowernumber,
                      $itemnumber,
                      $checkout->{issuedate},
                      $checkout->{date_due},
                      $checkout->{branchcode},
                      $checkout->{renewals},
                      );


    last if $number && $i == $number;
}
