# Objective
Create a docker script that automates Hutter Prize judging given an Entries/ subdirectory.

The detailed judging rules are at:
http://prize.hutter1.net/hrules.htm

An example subdirectory is Entries/Vladimir/

Note the files in that example directory:

(HutterPrize) jabowery@jaboweryML:~/devel/HutterPrize$ ls -altr Entries/Vladimir/
total 163196
-rw-rw-r-- 1 jabowery jabowery 70097602 Jul 27 14:29 fx2-cmix-transformer.tar.gz
drwxrwxr-x 3 jabowery jabowery     4096 Aug  5 16:10 ..
-rw-rw-r-- 1 jabowery jabowery 96996198 Aug  5 16:20 archive9
drwxrwxr-x 2 jabowery jabowery     4096 Aug  5 16:20 .
(HutterPrize) jabowery@jaboweryML:~/devel/HutterPrize$ 


archive9 is a purported executable archive of enwik9.
fx2-cmix-transformer.tar.gz contains the source code for the entry.
