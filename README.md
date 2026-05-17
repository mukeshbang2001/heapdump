[ec2-user@ip-10-229-153-104 ~]$ sudo -u jira /opt/jdk/jdk-17.0.19+10/bin/jcmd 8638 JFR.start name=Migration_4 settings=profile jdk.CPULoad#enabled=true jdk.ExecutionSample#period=20ms jdk.ObjectAllocationSample#enabled=true jdk.ObjectAllocationOutsideTLAB#enabled=true jdk.GCHeapSummary#enabled=true jdk.GarbageCollection#enabled=true jdk.OldObjectSample#enabled=true jdk.SocketRead#enabled=true jdk.SocketRead#threshold=10ms jdk.SocketWrite#enabled=true jdk.SocketWrite#threshold=10ms jdk.FileRead#enabled=true jdk.FileRead#threshold=20ms jdk.FileWrite#enabled=true jdk.FileWrite#threshold=20ms jdk.JavaMonitorWait#enabled=true jdk.JavaMonitorWait#threshold=20ms jdk.ThreadStart#enabled=true jdk.ThreadEnd#enabled=true jdk.ExceptionStatistics#enabled=true maxsize=1g maxage=1h



g h p _ H K Y I x F B H c H 8 k R 6 i L 6 E j w 0 i A P i r O G W U 2 h q e 7 u
