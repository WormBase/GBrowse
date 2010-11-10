#!/usr/bin/perl -w
# This script checks the schemas and required fields of the Users Database.
use strict;
use DBI;
use Bio::Graphics::Browser2 "open_globals";
use CGI::Session;
use Digest::MD5 qw(md5_hex);
use Getopt::Long;
use List::Util;

# First, collect all the flags - or output the correct usage, if none listed.
my ($dsn, $admin, $pprompt, $which_db, $force);
GetOptions('dsn=s'         => \$dsn,
           'admin|owner=s' => \$admin,
           'p'             => \$pprompt,
           'db=s'          => \$which_db,
           'f'             => \$force) or die <<EOF;
Usage: $0 [options] <optional path to GBrowse.conf>

Initializes an empty GBrowse user accounts database. Options:

   -admin     [Mysql only] DB admin user and password in format "user:password" [default "root:<empty>"]
   -owner     [SQLite only] Username and primary group for the Web user in the format "user:group"
   -p         Prompt for password
   -db        Specify which database ("users," "uploads" or "both")
   -f         Force the creation of a new database, regardless of pre-existing database.

Currently mysql and SQLite databases are supported. When creating a
mysql database you must provide the -admin option to specify a user
and password that has database create privileges on the server.

When creating a SQLite database, the script will use the -admin option
to set the user and group ID ownership of the created database in the
format "uid:gid". The web user must have read/write privileges to this
database. The user running this script must have "sudo" privileges for
this to work. Otherwise, you may set the ownership of the SQLite
database file manually after the fact.

Instead of providing the -dsn option, you may provide an optional path
to your installed GBrowse.conf file, in which case the value of
"user_account_db" will be used. If the config path and -dsn options
are both provided, then the latter overrides the former.
EOF
    ;

print STDERR "\n";

# Get any additional information needed.
until ($which_db) {
    print STDERR "Check which database - Users, Uploads or Both? ";
    chop ($which_db = <STDIN>);
}

my ($admin_user, $admin_pass) = split ':', $admin if $admin;
$admin_user ||= 'root';
$admin_pass ||= '';

if ($pprompt) {
    print STDERR "DB Admin password: ";
    $admin_pass = <STDIN>;
    chomp($admin_pass);
    print STDERR "\n";
}

# Open the connections.
my $globals = Bio::Graphics::Browser2->open_globals;
my $users_credentials  = $globals->user_account_db or die "No users database credentials specified in GBrowse.conf.";
my $userdb = DBI->connect($users_credentials) or die "Error: Could not open users database, please check your credentials.\n" . DBI->errstr;
my $uploads_credentials  = $globals->uploads_db or die "No uploads database credentials specified in GBrowse.conf.";

# Check the users DB, if requested.
my $checked = 0;
if ($which_db =~ /(user|both|all)/) {
    # Database schema. To change the schema, update/add the fields here, and run this script.
    my $users_columns = {
        userid => "varchar(32) not null UNIQUE key",
        uploadsid => "varchar(32)",
        username => "varchar(32) not null PRIMARY key",
        email => "varchar(64) not null UNIQUE key",
        pass => "varchar(32) not null",
        remember => "boolean not null",
        openid_only => "boolean not null",
        confirmed => "boolean not null",
        cnfrm_code => "varchar(32) not null",
        last_login => "timestamp not null",
        created => "datetime not null"
    };

    my $openid_columns = {
        userid => "varchar(32) not null",
        username => "varchar(32) not null",
        openid_url => "varchar(128) not null PRIMARY key"
    };
    
    check_table($userdb, "users", $users_columns);
    check_table($userdb, "openid_users", $openid_columns);
    check_uploads_ids($userdb);
    $checked = 1;
}

# Check the uploads DB, if requested.
if ($which_db =~ /(file|upload|both|all)/) {
    my $uploadsdb = DBI->connect($uploads_credentials) or die "Could not open uploads database, please check your credentials.\n" . DBI->errstr;
    
    # Database schema. To change the schema, update/add the fields here, and run this script.
    my $uploads_columns = {
        uploadid => "varchar(32) not null PRIMARY key",
        userid => "varchar(32) not null",
        path => "text",
        title => "text",
        description => "text",
        imported => "boolean not null",
        creation_date => "datetime not null",
        modification_date => "datetime",
        sharing_policy => "ENUM('private', 'public', 'group', 'casual') not null",
        users => "text",
        public_users => "text",
        public_count => "int"
    };
    
    check_table($uploadsdb, "uploads", $uploads_columns);
    check_all_files($userdb, $uploadsdb);
    $checked = 1;
    $uploadsdb->disconnect;
}
$userdb->disconnect;

print STDERR $checked? "Done!" : "Unknown DB - please enter \"Users,\" \"Uploads,\" or \"Both.\"";
print STDERR "\n\n";

exit 0;


# Check Table (DBI, Name, Columns) - Makes sure the named table is there and follows the schema needed.
sub check_table {
    my $data_source = shift or die "No database connection found, please check the gbrowse_metadb_config.pl script.\n";
    my $name = shift or die "No database name given, please check the gbrowse_metadb_config.pl script.\n";
    my $columns = shift  or die "No database schema given, please check the gbrowse_metadb_config.pl script.\n";
    my $type = $data_source->get_info(17); # Returns the database type.
    my $dsn = $data_source->{Driver}->{Name};

    # If the database doesn't exist, create it.
    unless ($data_source->do("SELECT * FROM $name LIMIT 1")) {
        print STDERR ucfirst $name . " table didn't exist, creating...";
        my @column_descriptors = map { "$_ " . escape_enums($$columns{$_}) } keys %$columns; # This simply outputs %columns as "$key $value, ";
        my $creation_sql = "CREATE TABLE $name (" . (join ", ", @column_descriptors) . ")" . (($type =~ /mysql/i)? " ENGINE=InnoDB;" : ";");
        $data_source->do($creation_sql) or die "Could not create $name database.\n";
        
        if ($type =~ /mysql/) {
            my $db_user = $dsn =~ /user=([^;]+)/;
            my $db_pass = $dsn =~ /password=([^;]+)/;
            $data_source->do("GRANT ALL PRIVILEGES on $name.* TO '$db_user'\@'%' IDENTIFIED BY '$db_pass' WITH GRANT OPTION") or die DBI->errstr;
        }
    }

    # If a required column doesn't exist, add it.
    my $sth = $data_source->prepare("SELECT * from $name LIMIT 1");
    $sth->execute;
    if (@{$sth->{NAME_lc}} != keys %$columns) {
        my @columns_to_create;
        my $run = 0;
        my $path = $dsn =~ /dbname=([^;]+)/;
        $path ||= $dsn =~ /DBI:SQLite:([^;]+)/;
        
        # SQLite doesn't support altering to add multiple columns or ENUMS, so it gets special treatment.
        if ($type =~ /sqlite/i) {
            # If we don't find a specific column, add its SQL to the columns_to_create array.
            foreach (keys %$columns) {
                $$columns{$_} = escape_enums($$columns{$_});
                
                # Now add each column individually
                unless ((join " ", @{$sth->{NAME_lc}}) =~ /$_/) {
                    my $alter_sql = "ALTER TABLE $name ADD COLUMN $_ " . $$columns{$_} . ";";
                    $data_source->do($alter_sql);
                }
                
                print STDERR "Using sudo to set ownership to $admin_user:$admin_pass. You may be prompted for your login password now.\n";
                die "Couldn't figure out location of database index from $dsn" unless $path;
                system "sudo chown $admin_user $path";
                system "sudo chgrp $admin_pass $path";
                print STDERR "Done.\n";
            }
        } else {
            # If we don't find a specific column, add its SQL to the columns_to_create array.
            foreach (keys %$columns) {
                unless ((join " ", @{$sth->{NAME_lc}}) =~ /$_/) {
                    push @columns_to_create, "$_ " . $$columns{$_};
                    $run++;
                }
            }
            
            # Now add all the columns
            warn ucfirst $name . " database schema is incorrect, adding " . @columns_to_create . " missing column" . ((@columns_to_create > 1)? "s." : ".");
            my $alter_sql .= "ALTER TABLE $name ADD (" . (join ", ", @columns_to_create) . ");";
            
            # Run the creation script.
            if ($run) {
                $data_source->do($alter_sql);
            }
        }
    }
    return $data_source;
}

# Check Uploads IDs (DBI) - Makes sure every user ID has an uploads ID corresponding to it.
sub check_uploads_ids {
    my $userdb = shift or die "No users database connection found, please check the gbrowse_metadb_config.pl script.\n";
    print STDERR "Checking uploads IDs in database...";
    my $ids_in_db = $userdb->selectcol_arrayref("SELECT userid, uploadsid FROM users", { Columns=>[1,2] });
    my %uploads_ids = @$ids_in_db;
    my $missing = 0;
    foreach my $userid (keys %uploads_ids) {
        unless ($uploads_ids{$userid}) {
            print STDERR "missing uploads ID found.\n" unless $missing;
            print STDERR "- Uploads ID not found for $userid, ";                
            my $session = CGI::Session->new($globals->session_driver, $userid, $globals->session_args);
            my $uploadsid = $session->param($globals->default_source)->{'page_settings'}->{'uploadid'};
            $userdb->do("UPDATE users SET uploadsid = " . $userdb->quote($uploadsid) . " WHERE userid = " . $userdb->quote($userid) . ";") or print STDERR "could not add to database.\n" . DBI->errstr;
            print STDERR "added to database.\n" unless DBI->errstr;
            $missing = 1;
        }
    }
    print STDERR "all uploads IDs are present.\n" unless $missing;
}

# Check All Files (DBI) - Calls check_files for every user.
sub check_all_files {
    my $userdb = shift or die "No uploads database connection found, please check the gbrowse_metadb_config.pl script.\n";
    my $uploadsdb = shift or die "No users database connection found, please check the gbrowse_metadb_config.pl script.\n";
    print STDERR "Checking for any files not in the database...";
    my $uploads_ids_ref = $userdb->selectcol_arrayref("SELECT uploadsid FROM users");
    my @uploads_ids = @$uploads_ids_ref;
    
    my $all_ok = 1;
    foreach (@uploads_ids) {
        my $this_ok = check_files($uploadsdb, $_);
        $all_ok = $this_ok if $all_ok;
    }
    print STDERR "all files are accounted for.\n" if $all_ok;
}

# Check Files (DBI, Uploads ID) - Makes sure a user's files are in the database, add them if not.
sub check_files {
    my $uploadsdb = shift or die "No uploads database connection found, please check the gbrowse_metadb_config.pl script.\n";
    my $uploadsid = shift or die "No upload ID given, please check the gbrowse_metadb_config.pl script.\n";
    
    # Get the files from the database.
    my $files_in_db = $uploadsdb->selectcol_arrayref("SELECT path FROM uploads WHERE userid = " . $uploadsdb->quote($uploadsid));
    my @files_in_db = @$files_in_db;
    
    # Get the files in the folder.
    my $path = $globals->user_dir($globals->default_source, $uploadsid);
	my @files_in_folder;
	opendir D, $path;
	while (my $dir = readdir(D)) {
		next if $dir =~ /^\.+$/;
		push @files_in_folder, $dir;
	}
	
	my $all_ok = 1;
	foreach my $file (@files_in_folder) {
	    my $found = grep(/$file/, @files_in_db);
	    unless ($found) {
	        print STDERR "missing file(s) found.\n" if $all_ok;
	        add_file($uploadsdb, $file, $uploadsid);
	        print STDERR "- File \"$file\" found in the \"$uploadsid\" folder without metadata, added to database.\n";
	        $all_ok = 0;
	    }
	}
	return $all_ok;
}

# Add File (Full Path[, Imported, Description, Sharing Policy, Owner's Uploads ID]) - Adds $file to the database under a specified owner.
# Database.pm's add_file() is dependant too many outside variables, not enough time to re-structure.
sub add_file {    
    my $uploadsdb = shift;
    my $filename = shift;
    my $imported = 0;
    my $description = $uploadsdb->quote("");
    my $uploadsid = shift;
    my $shared = $uploadsdb->quote("private");
    
    my $fileid = md5_hex($uploadsid.$filename);
    my $now = nowfun();
    $filename = $uploadsdb->quote($filename);
    $uploadsid = $uploadsdb->quote($uploadsid);
    $uploadsdb->do("INSERT INTO uploads (uploadid, userid, path, description, imported, creation_date, modification_date, sharing_policy) VALUES (" . $uploadsdb->quote($fileid) . ", $uploadsid, $filename, $description, $imported, $now, $now, $shared)");
    return $fileid;
}

# Now Function - return the database-dependent function for determining current date & time
sub nowfun {
    return $globals->uploads_db =~ /sqlite/i ? "datetime('now','localtime')" : 'now()';
}

# Escape Enums (type string) - If the string contains an ENUM, returns a compatible data type that works with SQLite.
sub escape_enums {
    my $string = shift;
    # SQLite doesn't support ENUMs, so convert to a varchar.
    if ($string =~ /^ENUM\(/i) {
        #Check for any suffixes - "NOT NULL" or whatever.
        my @options = ($string =~ m/^ENUM\('(.*)'\)/i);
        my @suffix = ($string =~ m/([^\)]+)$/);
        my @values = split /',\w*'/, $options[0];
        my $length = List::Util::max(map length $_, @values);
        $string = "varchar($length)" . $suffix[0];
    }
    return $string;
}