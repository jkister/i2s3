# i2s3

## watch for new files and upload them to s3

this utility makes it very easy to get files into a s3 bucket:
```
mkdir /tmp/i2s3q
cp /etc/hosts /tmp/i2s3q/hosts
# or
echo 1234 > /tmp/i2s3q/1234.txt
```

that's it - object is now stored on s3!

if pulic/http permissions are set on the bucket, you can browse:

 - https://s3.amazonaws.com/example_bucket/hosts
 - https://s3.amazonaws.com/example_bucket/1234.txt

files are stored based on your local directory structure:
```
mkdir -p /tmp/i2s3q/foo/bar/baz
echo test > /tmp/i2s3q/foo/bar/baz/test.txt
```
 - https://s3.amazonaws.com/example_bucket/foo/bar/baz/test.txt


### Usage:

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


### *NOTE: /not/ using --delete can incurr a large cost in cpu.  queue is most
efficient when a file is copied for s3 upload and no longer needed locally.

