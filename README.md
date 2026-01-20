# update_driver
Driver updating starting with just postgresql but will want mssql at some point and maybe the oracle client libraries later as well

NOTE:this has only been setup and tested for the 17.00.0006-mimalloc driver for postgresql at this point.  Any future driver will obviously need changes in the json file for the paths and url info for the driver but may require code change as will in the perl scripts if something was not made general enough originally.

Need to start the action runners on

di2usmif05254wh- open a powershell;C:\actions-runner;./run.cmd

cilv6s1090- open a session on cilv6s1090;cd /apps/action-runner; ./run.sh

this will output a file to /tc_work/nmb   names TOOLBOX.  Check the contents to ensure it has all the needed files for wntx64 and lnx64.







