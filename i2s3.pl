#!/usr/bin/perl

# i2s3 - watch a directory. upload files that appear to s3.
# Copyright (C) 2020 Jeremy Kister
# https://gitub.com/jkister/i2s3
# https://jeremy.kister.net/
# 2020050301

use strict;
use Amazon::S3;
use Digest::MD5;
use Sys::Syslog;
use MIME::Types;
use Linux::Inotify2;
use POSIX qw(setsid);
use Sys::SigAction qw(set_sig_handler);
use Getopt::Long qw(:config no_ignore_case);


my %opt = ( config    => '/etc/i2s3.cfg',
            name      => 'i2s3',
          );

GetOptions(\%opt, 'config|c=s',
                  'debug|D',
                  'quiet|Q',
                  'delete|d',
                  'foreground|f',
                  'piddir|p=s',
                  'queue|q=s',
                  'reprocess|r=i',
                  'syslog_facility|s=s',
                  'user|u=s',
                  's3_host=s',
                  'access_key_id=s',
                  'secret_access_key=s',
                  'bucket=s',
                  'help|h' => \&help,
          ) or die "error in command line arguments\n";

# backfill with config file if available
if( open(my $fh, $opt{config}) ){
    while(<$fh>){
        chop;
        s/\s*[;#].*//g;
        next if /^\s*$/;
        die "error in config line $.\n" unless /^(\S+)\s*=>?\s*(\S+)$/;

        next if $opt{$1};
        $opt{$1} = $2;
    }
    close $fh;
}else{
    warn "no config file or config file permissions problem. continuing anyway.\n";
}

$opt{queue}     ||= '/tmp/i2s3q';
$opt{reprocess} ||= 300;
$opt{s3_host}   ||= 's3.amazonaws.com';

if( $opt{quiet} && (! $opt{syslog_facility}) ){
    warn "no further logging output with --quiet and no --syslog_facility!\n";
}

for my $key (qw/access_key_id secret_access_key bucket/){
    $opt{$key} || die "specify [$key] in config file or command line\n";
}

# strip off leading part of the local filename to generate s3 storage name
# i.e., /tmp/foo/bar/whatever.xls -> bar/whatever.xls
$opt{strip} = length($opt{queue}) + 1; # +1 for trailing slash

mkpid(); # pre-fork, will change quickly if no -f

openlog($opt{name}, 'pid', $opt{syslog_facility}) if $opt{syslog_facility}; # sets up syslog

my $childpid;
daemonize(10) unless $opt{foreground};

chid($opt{user}) if $opt{user};

verbose("starting.");

set_sig_handler('ALRM', \&alrmhandler);
set_sig_handler('USR1', \&process_queue); # process queue now with kill -USR1
set_sig_handler('USR2', sub { $opt{debug} = $opt{debug} ? undef : 1; }); # dis/enable debug with kill -USR2

alarm($opt{reprocess}); # set the schedule to reprocess the local queue

my $s3 = Amazon::S3->new({ host => $opt{s3_host},
                           aws_access_key_id => $opt{access_key_id},
                           aws_secret_access_key => $opt{secret_access_key},
                           timeout => 10, # per request
                           retry => 1, # exponential backoff, 1,2,4..32, before retrying later
                         });

my $have_bucket;
for my $aref (@{ $s3->buckets->{buckets} }){
    if($aref->{bucket} eq $opt{bucket}){
        $have_bucket=1;
        last;
    }
}

my $bucket = $have_bucket ? $s3->bucket($opt{bucket}) : 
                            $s3->add_bucket({ bucket => $opt{bucket} });

my $md5  = Digest::MD5->new() unless $opt{delete}; # only if we need to track
my $mime = MIME::Types->new();

my %known; # track files in local dir -- for when without --delete

# if we keep local files, find out what's already in the bucket
my $in_bucket = get_inbucket($opt{bucket});

# listen for new kernel notifies on the main queue directory
my $i = Linux::Inotify2->new || slowerr("cannot create object: ", $!);
add_watcher($opt{queue}); # watch the main directory

# go through the existing queue and upload objects
process_queue($opt{queue});
undef $in_bucket; # not needed any more

while( 1 ){
    debug("start poll loop");
    1 while $i->poll; # interrupted by signals
}

sub process_queue {
    my $arg = shift || slowerr("specify process_queue dir");
    
    my $dir = $arg eq 'USR1' ? $opt{queue} : $arg;

    debug("processing dir: ", $dir);
    opendir(my $qdir, $dir) || slowerr("cannot open queue directory: ", $!);
    for my $file (grep {!/^\./} readdir $qdir){
        my $fname = "$dir/$file";
        if(-d $fname){
            add_watcher($fname);
            process_queue($fname);
            next;
        }elsif(! -f $fname){
            debug("queue skipping special file: ", $fname);
            next;
        }
 
        if($in_bucket){
            my $digest = get_digest($fname);
            my $rname = substr $fname, $opt{strip};
            if($in_bucket->{$rname} eq $digest){
                debug("local file $file matches remote md5 $digest");
                $known{$fname} = $digest;
                next;
            }
        }

        s3move($fname);
    }
    closedir $qdir;
}

sub get_inbucket {
    my $bucket = shift;

    return if $opt{delete};

    my %hash;
    for my $object (@{ $s3->list_bucket_all({ bucket => $bucket })->{keys} }){
        next unless $object->{size}; # 0 bytes are directories
        $hash{$object->{key}} = $object->{etag};
    }

    return \%hash;
}

sub get_digest {
    my $fname = shift || slowerr("specify argument to get_digest");

    open(my $fh, $fname) || slowerr("cant open $fname: ", $!);
    $md5->addfile($fh);
    close $fh;
    return $md5->hexdigest;
}

sub add_watcher {
    my $dir = shift;

    for my $k ( keys %{$i->{w}} ){
        return if $i->{w}{$k}{name} eq $dir; # already watching
    }

    debug("adding watcher to ", $dir);
    $i->watch($dir, IN_CREATE | IN_CLOSE_WRITE | IN_MOVED_TO, sub {
        my $e = shift;
        my $fname = $e->fullname; # nb $e->name is without path

        return if( $e->IN_IGNORED && (! -e $fname) ); # a removed directory

        if($e->IN_CREATE || $e->IN_ISDIR){
            # IN_CREATE picks up non-atomic copies.  so the only time we need
            # it is for mkdir /tmp/i2s3q/foo
            # IN_ISDIR w/o IN_CREATE is like mv /tmp/foo /tmp/i2s3q/foo
            next unless $e->IN_ISDIR;
            add_watcher($fname);
            process_queue($fname);
        }elsif(-f $fname){
             debug("see new file: ", $fname);
             s3move($fname);
        }else{
            debug("watcher skipping special file: ", $fname);
        }
    });
}

sub s3move {
    my $fname = shift || die "specify s3move localfile\n";

    debug("looking at file: ", $fname);
    unless(-s $fname){
        verbose("wont upload $fname: s3 cannot take 0 byte file");
        if($opt{delete}){
            debug("unlinking: ", $fname);
            unlink($fname) || verbose("could not delete $fname: ", $!);
        }
        return;
    }

    my $digest;
    unless($opt{delete}){
        # should this really be uploaded?
        $digest = get_digest($fname);
        if( $known{$fname} eq $digest ){
            debug("already uploaded this file");
            return;
        }
    }

    my $rname = substr $fname, $opt{strip};
    my $ct = $mime->mimeTypeOf($fname) || 'application/octet-stream';

    my $old_time;
    my $res;
    eval {
        my $h = set_sig_handler('ALRM', sub { die "timeout!\n" }); # QQQ ineffective when s3 retry=>1
        eval {
            my $old_alarm = alarm(15); # just lets us track before add_key_filename stomps on it
            $old_time = time() + $old_alarm;

            $res = $bucket->add_key_filename($rname, $fname, {'Content-Type' => $ct});
            alarm(0);
        };
        alarm(0);
        die $@ if $@;
    };
    if($@){
        verbose("eval caught exception: ", $@);
    }elsif($bucket->errstr){
        # alarm could be ready to immediately go again, causing a loop here.
        # that's okay, it doesnt matter which file we're stuck on uploading.
        verbose("S3 ERROR: ", $bucket->errstr);
    }elsif(! $res){
        # unknown errors happen here.  like uploading a 5gb+1byte file. or uploading with wrong aws permissions.
        # QQQ why isnt that trapped by errstr??? 
        verbose("Uncaught S3 error");
    }else{
        verbose("added $fname to s3://$opt{bucket}/$rname");
        if($opt{delete}){
            debug("unlinking: ", $fname);
            unlink($fname) || verbose("could not delete $fname: ", $!);
        }else{
            # save that i know about this file for reprocess_queue
            $known{$fname} = $digest;
        }
    }

    my $delta = $old_time - time();
    my $nalarm = $delta > 1 ? $delta : 1; # smallest sleep is 1
    debug("setting alarm for $nalarm seconds");
    alarm($nalarm);
}

sub verbose {
    my ($msg) = join '', @_;

    warn "$msg\n" if($opt{foreground} && (! $opt{quiet}));
    syslog('info', $msg) if $opt{syslog_facility};
}

sub debug {
    my ($msg) = join '', @_;

    return unless $opt{debug};
    warn "DEBUG: $msg\n" if($opt{foreground} && (! $opt{quiet}));
    syslog('debug', $msg) if $opt{syslog_facility};
}

sub slowerr {
    verbose @_;

    sleep 15;
    exit 1;
}

sub chid {
    my $user = shift || die "specify user in chid\n";

    my ($uid,$gid) = (getpwnam($user))[2,3];

    if($uid == $>){
        debug("already running as chid user: ", $uid);
        return;
    }

    unless($> == 0 || $< == 0){
        slowerr("cannot chid when not running as root.");
    }
    unless($uid && $gid){
        slowerr("cannot chid to $user: uid not found.");
    }

    debug("switching uid/gid to $uid/$gid");
    $! = 0;
    $( = $) = $gid;
    slowerr("unable to chgid $user: ", $!) if $!;
    $< = $> = $uid;
    slowerr("unable to chuid $user: ", $!) if $!;

}

sub mkpid {

    return unless $opt{piddir};

    my $pidfile = "$opt{piddir}/$opt{name}.pid";

    open(my $pidf, ">$pidfile") || slowerr("cannot write to pid file $pidfile: ", $!);
    print $pidf "$$\n";
    close $pidf;
}

sub daemonize {
    my $to = shift;

    fork && exit;
    chdir($opt{queue}); # regardless of where i was spawned (release nfs, et al)

    close STDIN;   open( STDIN,  '<',  "/dev/null" );
    close STDOUT;  open( STDOUT, '>>', "/dev/null" );
    close STDERR;  open( STDERR, '>>', "/dev/null" );
    setsid();

    $SIG{HUP} = $SIG{QUIT} = $SIG{INT} = $SIG{TERM} = sub { sighandler(@_) };

    mkpid();

    # run as 2 processes
    while(1){
        if($childpid = fork){
            # parent
            wait;
            my $xcode = $?;
            $childpid = undef;
            verbose("$opt{name} exited with code $xcode - restarting in $to seconds");
            sleep $to;
        }else{
            # child
            return;
        }
    }
}

sub sighandler {
    if($childpid > 0){
        unlink("$opt{piddir}/$opt{name}.pid") || verbose("cannot unlink $opt{piddir}/$opt{name}.pid: $!");
        kill "TERM", $childpid;
        wait;
    }
    verbose("caught SIG$_[0] - exiting");
    exit;
}

sub alrmhandler {
    debug( "got in alarm handler." );

    alarm(0);

    # reprocess queue.  find failed uploads and try again
    # possibly finds new subdirs/files that werent handled b/c race cond or overflow
    process_queue($opt{queue});

    alarm($opt{reprocess});
}

sub help {
    print <<__EOH__

    i2s3 - watch for new files in a specified directory and upload them to s3.

    -c, --config            config file [/etc/i2s3.cfg]
    -h, --help              don't print this message

    all below parameters (long versions) can be specified in a config file
    with format 'key => value'.  command line arguments override config file.

    -D, --debug             print debug messages
    -Q, --quiet             hush console output

    -d, --delete            delete local files after uloading to s3 (*recommended)
    -f, --foreground        stay foreground; dont fork
    -p, --piddir            create pid file here
    -q, --queue             queue directory to monitor
    -r, --reprocesss        reprocess queue this many seconds (for failed uploads, et. al.) [300]
    -s, --syslog_facility   send syslog messages to this facility (none if not specified)
    -u, --user              user to run as

    --s3_host               s3 server hostname      [s3.amazonaws.com]
    --access_key_id         use this aws access key id
    --secret_access_key     use this aws secret
    --bucket                upload objects to this s3 bucket

__EOH__
    ;
    exit;
}
