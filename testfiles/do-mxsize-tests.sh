#!/bin/bash

RETVAL=0;

$VADRSCRIPTSDIR/v-test.pl -f --rmout $VADRSCRIPTSDIR/testfiles/noro.mxsize.testin vt-noro-mxsize
if [ $? != 0 ]; then
   RETVAL=1;
fi   

if [ $RETVAL == 0 ]; then
   echo "Success: all tests passed"
   exit 0
else 
   echo "FAIL: at least one test failed"
   exit 1
fi
