# PollRepair - A Plugin to Replace Vera's Built-in Polling

*PollRepair* is a plugin replacement for Vera Luup's broken polling. 

It does not run on openLuup. If you are an openLuup (or Hass or other) user bridging a Vera, PollRepair can and should be run on the Vera itself.

## Why PollRepair?

Vera's polling is verifiably broken. At a certain point, it collapses under its own weight, often taking the mesh with it. The first most-observable evidence of its flaws are that devices are not polled on time in large networks. Other observations include suspected bugs in concurrency or mesh interaction that cause deadlocks and Luup reloads when polling and other mesh activities are done at the same time.

While we cannot examine the code to determine exact reasons why these might be, there is evidence in the log files of a few things. First, they've made some bad implementation choices (everyone who has been on Vera for any length of time will not be shocked by this revelation). For example, at around 50 ZWave nodes, messages to the effect that the poll list is full and a device is being bumped off the list start rolling in. 

```
02	08/27/20 15:47:27.239	Device_Basic::AddPoll 446 poll list full, deleting old one <0x77370520>
```

"Full"? Hmmm. This suggests the list has a fixed upper limit, confirmed by the observation that the more nodes, the more frequent these messages. Users also begin to notice that the polling of certain devices is not happening in a timely way, and the result is that devices that need to polled have inaccurate status/data for unpredictable amounts of time. And again, the more nodes, the worse this becomes. A fixed-size list is a poor choice on its own (particularly since the system limit on the number of ZWave devices is very low in computing terms). Nonetheless, it's clear that when the list limit is reached, something is being thrown off the list.

Second, there appears to be no priority in what gets thrown off the list other than how many are on the list--the first one put on is the first one thrown off. This is troublesome, because it makes no provision for how "tardy" the poll is, so a node that has missed a poll interval could, in a large enough network, keep getting thrown off the list and *never* get polled. Eventually it really becomes blind luck that the device doesn't get thrown off if it does eventually get polled.

Finally, (my software engineer friends are going to love this one) Luup puts *all devices* on the polling list whether they are configured for polling or not. It is only later, when the polling process pops the device from the polling list that it determines there is nothing for it to do. So not only do polling-disabled devices thus keep generating trivial busy work ("on the list, nothing to do, off the list" lather rinse repeat ad infinitum), but because of the fixed list size, *non-polled devices are bumping polled devices off the list*, exacerbating all of the previously-mentioned brokenness. Disabling polling on a single device doesn't help you avoid the list overflow problem, and thus doesn't improve the consistency of polling in the system when the number of nodes exceeds the list size.

Again, we don't have access to Vera's code to verify behavior, but this is what I can observe and surmise from the messages in the log files. And in all, it means that once the number of nodes grows to a certain size, Luup's polling becomes irretreivable broken and goes random, and is thus little more than a driver of bogus traffic in the mesh that isn't serving the needs of the mesh as a whole.

## How Does PollRepair Work

PollRepair works by finding the pollable devices in the system and telling Vera not to poll them, while it continues in the background doing the polling itself. PollRepair does not use a fixed list; the poll list in PollRepair is dynamic and grows and shrinks to suit the number of eliglble devices. Devices are managed on the list so that the nodes with the most-tardy polls bubble to the top &mdash; the longer since a poll interval was missed, the more urgent that node becomes in the queue. This is completely dynamic and constantly changing. It is also resilient across Luup reloads, of course, because that's how I roll. Nodes stay on schedule to the greatest degree possible, and when it's not possible, PollRepair works to get them back on schedule ASAP.

Battery-operated devices are skipped *mdash; some of these are polled on Vera, and require a special approach to polling from the firmware that cannot easily be circumvented or duplicated, so we allow Vera to continue to poll these devices itself. As a an aside, it is not clear that battery-operated devices really need to be polled at all (the device's wake-ups usually serve the purpose).

## Installing

To install PollRepair:

1. Go its Github repository;
2. Click the green "Download or clone" button and choose "Download ZIP";
3. Save the ZIP file somewhere;
4. Unzip the archive;
5. Open the Luup upload in UI7 at *Apps > Develop apps > Luup files*;
6. Drag and drop the unzipped files (no folders; and skip the `.md` files) to the "Upload" button as a group.
7. Wait for Luup to reload.
8. [Hard refresh your browser](https://www.getfilecloud.com/blog/2015/03/tech-tip-how-to-do-hard-refresh-in-browsers/).

## Setting Up

When PollRepair is first installed, it is self-disabled. You must explicitly enable it for it to begin working. Nothing on your system will change until you enable it.

**Back up your system and Z-Wave network before enabling PollRepair, or even before installing it. This way you know you have a good backup.**

When you enable PollRepair, it will configure itself and the devices using the polling intervals configured in each device's Vera-standard `PollSettings` variable (blank=system default interval, 0=don't poll, >0=interval in seconds). Once done, it sets this variable to 0, which keeps Vera from attempting to poll the node and lets PollRepair do it. The original polling interval from `PollSettings` is copied to `tb_pollsettings` during initialization, and this is what PollRepair uses for timing. See the "Special Configuration" section below for instructions on how to change the pollling interval once PollRepair is enabled. **Do not change `PollSettings` when PollRepair is enabled.**

After device initialization, PollRepair begins polling your devices. A count of pollable devices is shown in PollRepairs dashboard card, along with a count of devices in the queue that need to be polled immediately. This number will start out high, and slowly trend toward zero. It may take several minutes or even hours for this to occur, depending on your polling configuration and number of nodes. Don't worry, be patient. Eventually, it will settle in where the number of "ready" devices is very low, often zero. That's normal and good.

Luup reloads will, of course, interrupt the polling process and cause delays. After a reload, you may notice that the number of "ready" devices jumps up. Just as before, it will settle down as PollRepair catches up after the reload.

If you disable PollRepair using its dashboard button, the plugin will restore Vera's polling configuration to all devices and step out of the process. Vera will again be in charge of polling all devices on the schedule you configured for each. So if you suspect PollRepair is causing problems, it's easy to disable and restore your original configuration (without restoring a backup).

## Special Configuration

If you have a device that you do not want PollRepair to manage, you can mark it by creating a state variable called `tb_verapollonly` in service `urn:micasaverde-com:serviceId:ZWaveDevice1` and setting it to 1 (or non-zero integer). This is easily done in the device's control panel, on the *Advanced > New Service" tab.
Setting it to 0 will again allow PollRepair to manage the device. Whenever you create or change this value, if PollRepair is enabled, you should disable it and then re-enable it. Luup reload is not necessary.

Once PollRepair is in control, you can change the polling interval of a device by changing the `tb_pollsettings` state variable, **not `PollSettings`.
** Do not change `PollSettings` when PollRepair is enabled, or you could end up with both Vera and PollRepair trying to poll the device. Only `tb_pollsettings` should be changed on PollRepair-controlled devices.

PollRepair logs its activity in level 4 of the LuaUPnP log file. If you normally have this disabled, you will not see PollRepair's messages.

## Other Things

* PollRepair does *not* honor Vera's polling process settings in the *Settings > Z-Wave Settings* tab of the UI (UI7). Changing these settings does not affect PollRepair's behavior in any way.
* The minimum polling interval is 60 seconds. PollRepair will not poll a device more frequently than this.
* While PollRepair is operating, you may still see Vera/Luup's messages about the polling list being full. This is normal and can be safely ignored. You'll see other messages to let you know that PollRepair is working, and of course, you'll be able to observe its effect on device states. Here's a snippet of what your logs will typically show:

```
04	08/27/20 15:48:00.110	luup_log:483: PollRepair: Polling "Foyer Receptacle" (device 370, ZWave node "160") delayed 3s <0x73d70520>
08	08/27/20 15:48:00.110	JobHandler_LuaUPnP::HandleActionRequest device: 370 service: urn:micasaverde-com:serviceId:HaDevice1 action: Poll <0x73d70520>
04	08/27/20 15:48:00.230	<Job ID="34906" Name="pollnode_sms2 #160 1 cmds" Device="370" Created="2020-08-27 15:48:00" Started="2020-08-27 15:48:00" Completed="2020-08-27 15:48:00" Duration="0.119163000" Runtime="0.117888000" Status="Successful" LastNote="SUCCESS! Successfully polled node" Node="160" NodeType="ZWaveNonDimmableLight" NodeDescription="Foyer Receptacle"/> <0x77370520>
02	08/27/20 15:48:00.231	Device_Basic::AddPoll 370 poll list full, deleting old one <0x77370520>
04	08/27/20 15:48:05.101	luup_log:483: PollRepair: Successful poll of "Foyer Receptacle" (#370), next 1598558264(08/27/20.15:57:44) (interval 600) <0x73d70520>
04	08/27/20 15:48:05.108	luup_log:483: PollRepair: Polling "Classroom Near" (device 123, ZWave node "110") delayed 1s <0x73d70520>
08	08/27/20 15:48:05.109	JobHandler_LuaUPnP::HandleActionRequest device: 123 service: urn:micasaverde-com:serviceId:HaDevice1 action: Poll <0x73d70520>
04	08/27/20 15:48:05.250	<Job ID="34907" Name="pollnode_sms2 #110 1 cmds" Device="123" Created="2020-08-27 15:48:05" Started="2020-08-27 15:48:05" Completed="2020-08-27 15:48:05" Duration="0.140374000" Runtime="0.138968000" Status="Successful" LastNote="SUCCESS! Successfully polled node" Node="110" NodeType="ZWaveDimmableLight" NodeDescription="Classroom Near"/> <0x77370520>
02	08/27/20 15:48:05.251	Device_Basic::AddPoll 123 poll list full, deleting old one <0x77370520>
04	08/27/20 15:48:10.101	luup_log:483: PollRepair: Successful poll of "Classroom Near" (#123), next 1598558283(08/27/20.15:58:03) (interval 600) <0x73d70520>
04	08/27/20 15:48:10.109	luup_log:483: PollRepair: Polling "Bridge Receptacle" (device 72, ZWave node "82") delayed 3s <0x73d70520>
08	08/27/20 15:48:10.109	JobHandler_LuaUPnP::HandleActionRequest device: 72 service: urn:micasaverde-com:serviceId:HaDevice1 action: Poll <0x73d70520>
04	08/27/20 15:48:10.230	<Job ID="34908" Name="pollnode_sms2 #82 1 cmds" Device="72" Created="2020-08-27 15:48:10" Started="2020-08-27 15:48:10" Completed="2020-08-27 15:48:10" Duration="0.120119000" Runtime="0.119603000" Status="Successful" LastNote="SUCCESS! Successfully polled node" Node="82" NodeType="ZWaveNonDimmableLight" NodeDescription="Bridge Receptacle"/> <0x77370520>
02	08/27/20 15:48:10.231	Device_Basic::AddPoll 72 poll list full, deleting old one <0x77370520>
04	08/27/20 15:48:15.101	luup_log:483: PollRepair: Successful poll of "Bridge Receptacle" (#72), next 1598558314(08/27/20.15:58:34) (interval 600) <0x73d70520>
04	08/27/20 15:48:15.109	luup_log:483: PollRepair: Polling "Classroom Main" (device 122, ZWave node "109") delayed 5s <0x73d70520>
08	08/27/20 15:48:15.109	JobHandler_LuaUPnP::HandleActionRequest device: 122 service: urn:micasaverde-com:serviceId:HaDevice1 action: Poll <0x73d70520>
04	08/27/20 15:48:15.242	<Job ID="34909" Name="pollnode_sms2 #109 1 cmds" Device="122" Created="2020-08-27 15:48:15" Started="2020-08-27 15:48:15" Completed="2020-08-27 15:48:15" Duration="0.132171000" Runtime="0.131506000" Status="Successful" LastNote="SUCCESS! Successfully polled node" Node="109" NodeType="ZWaveDimmableLight" NodeDescription="Classroom Main"/> <0x77370520>
02	08/27/20 15:48:15.243	Device_Basic::AddPoll 122 poll list full, deleting old one <0x77370520>
04	08/27/20 15:48:20.101	luup_log:483: PollRepair: Successful poll of "Classroom Main" (#122), next 1598558286(08/27/20.15:58:06) (interval 600) <0x73d70520>
04	08/27/20 15:48:20.108	luup_log:483: PollRepair: Polling "Family Rm Pathway" (device 377, ZWave node "167") delayed 4s <0x73d70520>
08	08/27/20 15:48:20.109	JobHandler_LuaUPnP::HandleActionRequest device: 377 service: urn:micasaverde-com:serviceId:HaDevice1 action: Poll <0x73d70520>
04	08/27/20 15:48:20.234	<Job ID="34910" Name="pollnode_sms2 #167 1 cmds" Device="377" Created="2020-08-27 15:48:20" Started="2020-08-27 15:48:20" Completed="2020-08-27 15:48:20" Duration="0.124185000" Runtime="0.123688000" Status="Successful" LastNote="SUCCESS! Successfully polled node" Node="167" NodeType="ZWaveNonDimmableLight" NodeDescription="Family Rm Pathway"/> <0x77370520>
02	08/27/20 15:48:20.235	Device_Basic::AddPoll 377 poll list full, deleting old one <0x77370520>
```

