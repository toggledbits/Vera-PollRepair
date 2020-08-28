# PollRepair - A Plugin to Replace Vera's Built-in Polling

*PollRepair* is a plugin replacement for Vera Luup's broken device polling.

## Why PollRepair?

Vera's device polling is verifiably broken, and has been for a long time. At a certain point, it collapses under its own weight and bugs, sometimes taking the mesh with it. The first most-observable evidence of its flaws are that devices are not polled on time in large networks. Other observations include suspected bugs in concurrency or mesh interaction that cause deadlocks and Luup reloads when polling and other mesh activities are done at the same time.

While we cannot examine the code to determine exact reasons why these might be, there is evidence in the log files of a few things. 
First, at around 50 ZWave nodes, messages declaring the poll list to be full start rolling in:

```
02	08/27/20 15:47:27.239	Device_Basic::AddPoll 446 poll list full, deleting old one <0x77370520>
```

"Full"? "Deleting old one"? Hmmm. This suggests the list has a fixed upper limit and devices are thrown off arbitrarily when the limit is reached. This is confirmed by the observation that the more nodes, the more frequent these messages. Users also begin to notice that the polling of certain devices is not happening in a timely way, and the result is that devices that need to polled have inaccurate status/data for unpredictable amounts of time. And again, the more nodes, the worse this becomes.

> SIDEBAR: It's hard to imagine a worse implementation choice here than a fixed size list, except for choosing a fixed size that's too small to accomodate the system capacity. The maximum number of ZWave nodes in the system is only 232, which is pretty small even for the modest CPU and RAM on which Luup runs. There's really not even a reason to have a fixed list at all: a linked list of nodes would serve better from adding and removing devices dynamically, growing and shrinking as needed, consuming little RAM even in the worst case. There is no reason for the polling list to ever be "full;" that's a concept that should not apply. It should be large enough to accomodate every single device that needs to be polled, without having to bump a device off the list, ever. And that's especially true given that the maximum number of devices that would ever be polled is relatively small.

Second, when the list gets "full," there appears to be no priority given to what gets thrown off the list other than how many are on the list. This is troublesome, because it makes no provision for how "tardy" the poll for the device is, so a node that has missed a poll interval could, in a large enough network, keep getting thrown off the list and basically *never* get polled. Whether or not a device gets polled at all now becomes more a game of chance than a deterministic algorithm.

> SIDEBAR: My own house Vera system, with 100-ish ZWave nodes, had a large number of devices that were polled perhaps only once or twice a day, randomly, despite being configured to poll every 10 or 30 minutes.

Third, (my software engineer friends are going to love this one) it appears that Luup puts *all nodes* on the polling list, whether they are configured for polling or not. It is only later, when the polling process pops the device from the list that it determines that there is no work to be done for that device. Not only does this waste cycles (fussing with devices that don't need to be fussed with), but because of the fixed list size, *these non-polled devices are bumping devices that need to be polled off the list* &mdash; they take up a slot in the list that they don't need &mdash; exacerbating all of the previously-mentioned brokenness. Disabling polling on a device doesn't help you avoid the list overflow problem, and thus doesn't improve the consistency of polling in the system when the number of nodes exceeds the list size.

> SIDEBAR: This is another really poor engineering choice. Clearly, the determination of whether a device needs to be polled or not should be made *before* putting the device on the list. Don't put it on the list in the first place if it doesn't need to be polled. At least then, as a workaround for the low fixed list size, you could configure less-critical devices in the system to not poll, so they would never be on the list, and the limited capacity of the list would then be reserved for only the devices that need polling. Unfortunately, this is not the case, so no workaround is possible.

Again, we don't have access to Vera's code to verify these bugs in hard statements, but this is what I can observe and surmise from the messages in the log files. And in all, it means that once the number of nodes added to the system exceeds a certain low number (seems like 50), Luup's polling goes random, and becomes little more than a driver of bogus traffic in the mesh and busy work that isn't serving the needs of the mesh as a whole.

Finally, we know that there are various problems with concurrency and message handling in the firmware, some of which appear to be exacerbated by the polling process, causing deadlocks and missed devices messages. I don't expect PollRepair to be able to affect much here, as these are internal issues of the Luup and ZWave stack implementation, but it's possible that just changing the approach by using PollRepair takes enough of a different path that some of these landmines might be missed.

## How PollRepair Works

PollRepair works by finding the pollable devices in the system and telling Vera not to poll them, while it continues in the background doing the polling itself. PollRepair does not use a fixed list; the poll list in PollRepair is dynamic and grows and shrinks to suit the number of eliglble devices. Devices are managed on the list so that the nodes with the most-tardy polls bubble to the front of the line &mdash; the longer since a poll interval was missed, the more urgent that node becomes to be handled. This is completely dynamic and constantly adaptive. It is also resilient across Luup reloads (of course, because that's how I roll). Nodes stay on schedule to the greatest degree possible, and when it's not possible, PollRepair works to get them back on schedule ASAP.

Battery-operated devices are skipped &mdash; some of these are polled on Vera, and require a special approach to polling from the firmware that cannot easily be circumvented or duplicated, so we allow Vera to continue to poll these devices itself. As a an aside, it is not clear that battery-operated devices really need to be polled at all (the device's wake-ups usually serve the purpose).

## System Requirements

PollRepair is intended to run on Vera Plus, Edge and Secure systems running firmware 7.0.31 or higher. It has not been tested on (and is not targeted for) Vera3 or Lite systems.

It does not run on openLuup directly. But, if you are an openLuup (or Hass or other) user with a bridged Vera system, PollRepair can be run on the Vera itself.

## Installing

**Before proceeding, this is a good time to make a full backup of your system, including the ZWave dongle.**

**CAVEAT USER: PollRepair is experimental! Use at your own risk!** I have long seen the issues in Luup's polling, and finally became determined to see if there was something I could do about it from the rather "external" environment of a plugin, the only access we're given. It relies on a lot of detective work (guess work), and a lot of assumptions. I have run it on my own house system for months, and my system is stable and goes long stretches without reloads. That said, your experience may be different. Everyone has different devices, different configurations, and I've even found that the order in which devices are added to the system (which affects the order of initialization) can have interesting (there's a word) effects on system stability. It is unlikely PollRepair will harm your system, I think, but given what we know of Vera and some of its design choices, it is always possible for some previously-unheard-of side-effect to rear its ugly head in an unfortunate way. Backups are your friend.

There are two ways to get PollRepair, but both of them source from its [Github repository](https://github.com/toggledbits/Vera-PollRepair):

* The latest released version is always on [the *master* branch](https://github.com/toggledbits/Vera-PollRepair/tree/master). Click the green "Code" button and choose "Download ZIP". Save the ZIP file somewhere and continue below.
* All released packages can be found in the [repository's releases list](https://github.com/toggledbits/Vera-PollRepair/releases). You can download any release package by clicking on its "Source code (zip)" link. Save the ZIP file somewhere and continue below.

To install:

1. Unzip the archive;
2. Open the Luup uploader in UI7 at *Apps > Develop apps > Luup files*;
3. Select, drag and drop the unzipped files (no folders; and skip the `.md` files) to the "Upload" button as a group;
4. Wait for Luup to reload;
5. Go to *Apps > Develop apps > Create Device* and enter the following:
   ```
   Description: PollRepair
   UPnP Device Filename: D_PollRepair.xml
   UPnP Implementation Filename: I_PollRepair.xml
   ```
6. Hit the "Create device" button;
7. Reload Luup (e.g. you can run `luup.reload()` in *Apps > Develop apps > Test Luup code*);
8. [Hard refresh your browser](https://www.getfilecloud.com/blog/2015/03/tech-tip-how-to-do-hard-refresh-in-browsers/);

## Setting Up

When PollRepair is first installed, it is self-disabled. You must explicitly enable it for it to begin working. Nothing on your system will change until you enable it.

**Back up your system and Z-Wave network before enabling PollRepair, or even before installing it. This way you know you have a good backup.**

When you enable PollRepair, it will configure itself and the devices using the polling intervals configured in each device's Vera-standard `PollSettings` variable (blank=system default interval, 0=don't poll, >0=interval in seconds). Once done, it sets this variable to 0, which keeps Vera from attempting to poll the node and lets PollRepair do it. The original polling interval from `PollSettings` is copied to `tb_pollsettings` during initialization, and this is what PollRepair uses for timing. If you need to change the polling interval, _you can change either `PollSettings` or `tb_pollsettings`_ and PollRepair will pick up the change. That means the UI7 GUI for changing the polling interval still works, too.

After device initialization, PollRepair begins polling your devices. A count of pollable devices is shown in PollRepair's dashboard card, along with a count of devices in the queue that need to be polled immediately ("ready" devices). The number of ready devices will start out high, and slowly trend toward zero. It may take several minutes or even hours for this to occur, depending on your polling configuration and number of nodes. Don't worry, be patient. Eventually, it will settle in where the number of "ready" devices is very low, often zero. That's normal and good.

Luup reloads will, of course, interrupt the polling process and cause delays. After a reload, you may notice that the number of "ready" devices jumps up. Just as before, it will settle down as PollRepair catches up after the reload.

If you disable PollRepair using its control panel switch/button, the plugin will restore Vera's polling configuration to all devices and step out of the process. Vera will again be in charge of polling all devices on the schedule you configured for each. So if you suspect PollRepair is causing problems, it's easy to disable and restore your original configuration (without restoring a backup).

## Special Configuration

If you have a device that you do not want PollRepair to manage, you can mark it by creating a state variable called `tb_verapollonly` in service `urn:micasaverde-com:serviceId:ZWaveDevice1` and setting it to 1. This is easily done in the device's control panel, on the *Advanced > New Service* tab.
Setting it to 0 will again allow PollRepair to manage the device. Whenever you create or change this value, if PollRepair is enabled, you should disable it and then re-enable it. Luup reload is not necessary.

## Other Things

* PollRepair does *not* honor Vera's polling process settings in the *Settings > Z-Wave Settings* tab of the UI (UI7). Changing these settings does not affect PollRepair's behavior in any way.
* The minimum polling interval is 60 seconds. PollRepair will not poll a device more frequently than this.
* PollRepair logs its activity in level 4 of the LuaUPnP log file. If you normally have this level (job logging) disabled, you will not see PollRepair's messages.
* While PollRepair is operating, **you may still see Vera/Luup's messages about the polling list being full** ("poll list full, deleting old one"). This is normal (it's the side-effect of the third bug mentioned in "Why PollRepair?" above) and can be safely ignored. You'll see other messages to let you know that PollRepair is working, and of course, you'll be able to observe its effect on device states. Here's a snippet of what your logs will typically show:

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
