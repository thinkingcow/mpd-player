#!/bin/sh
# the next line restarts using wish \
exec wish "$0" ${1+"$@"}

# Music player control (C) S Uhler, 2021, 2022
# Intended for use with wish8.6
# This is the "all in one file" standaline version
# - change the host in m_open to point to your mpd daemon
# - runs as an android app using "androwish"
# - Communucates using the mpd socket protocol
# - use the scroll wheel to resize text
# - can be resized fairly arbitrarily

# Theory of operation
# - keeps one socket to mpd open
# - stays in the "idle" mpd state, to receive async events from mpd
# - commands are placed on a Queue, which are send to mpd by setting
#   mpd into "noidle" mode, sending the Q'd commands, then returning to idle mode

proc debug {msg} {
  set l [info level]
  incr l -1
  set n [lindex [info level $l] 0]
  puts stderr "$n: $msg"
}

# mpd socket interface
# see: https://mpd.readthedocs.io/en/latest/protocol.html

proc m_open {callback {host 192.168.1.56} {port 6600}} {
  if {[catch "socket $host $port" sock]} {
    debug "Cant open socket: $sock"
    return -code error
  }
  fconfigure $sock -blocking 1 -buffering line
  enq status listplaylists outputs clearerror
  fileevent $sock readable [list $callback $sock]
  return $sock
}

proc m_command {sock args} {
  foreach cmd $args {
    enq $cmd
  }
  cmd $sock noidle
}

set S(command) start
proc cmd {sock cmd} {
  global S
  debug $cmd
  set S(command) [lindex $cmd 0]
  if {[catch {
    puts $sock $cmd
  }]} {
    global ErrorInfo
    debug "Error running ($cmd): $ErrorInfo"
    set S(command) error
    set_status "Socket died sending command, restarting..."
    after 1000 start_service
  }
}

# read response from the socket
proc m_response {sock} {
  global S
  gets $sock line
  if {$line == ""} {
    close $sock
    set_status "Socket died reading response, restarting"
    after 1000 start_service
    return
  }
  if {[regexp {^(OK|ACK)} $line all code]} {
    debug "$S(command) complete: $code"
    if {$S(command) == "listplaylists"} {
      update_channels
    }
    if {$S(command) == "outputs" && [llength [grid slaves .outputs]] == 0} {
      debug "creating output buttons"
      create_outputs
    }
    if {![deq $sock]} {
       cmd $sock "idle"
       if {[info exists S(error)]} {
         set_status "Server error: $S(error)"
         unset S(error)
       }
    }
  } elseif {[regexp {(^[^:]+): *(.*)} $line all n v]} {
    process_key $sock $n $v
  } else {
    set_status "Unknown response  from $S(cmmand): $line"
  }
}

# handle key: value responses from MPD
proc process_key {sock n v} {
  global S
  set S($n) $v
  # debug "key: ($n) = ($v)"
  switch -exact $n {
    playlist {
      # playlist meaning changes based on command
      global S
      if {$S(command) != "status"} {
        global Channels
        lappend Channels $v
      }
    }
    song {
      enq "playlistinfo $v"
    }
    changed {
      debug "changed event ($v)"
      if {[regexp {^mixer|player$} $v]} {
        enq status 
        catch {clear_fields .}
      } elseif {$v == "stored_playlist"} {
        enq listplaylists
        set_status "updating playlists"
      } elseif {$v == "output"} {
        set_status "Output changed"
        enq outputs
      } else {
        set_status "unknown change: $v"
      }
     
    }
    outputid {
      global O_id 
      set O_id $v
    }
    outputname {
      global Outputs O_id 
      set Outputs($O_id) $v
    }
    outputenabled {
      global Enabled O_id 
      set Enabled($O_id) $v
    }
  }
}

# enqueue a command to run when current command is done
set Q ""
proc enq {args} {
  global Q
  lappend Q {*}$args
}

# Run next q'd command, if available
proc deq {sock} {
  global Q
  if {[llength $Q] == 0} {
    return 0
  }
  cmd $sock [lindex $Q 0]
  set Q [lrange $Q 1 end]
  return 1
}

proc do_playlist {sock name} {
  m_command $sock clear "load $name" play
}

proc start_ui {} {
  global S State
  set S(command) idle
  set State "Starting..."
  ui
  help
  wm title . "MPD Music Player v0.2"
  after idle {bind .data_frame <Configure> title_width}
  after idle {trace add variable S(command) write update_state}
}

proc start_service {} {
  global Socket
  catch {close $Socket}
  set Socket [m_open m_response]
}

# define font categories
set My_fonts "label title button value"
set Min_font_size 6
set Max_font_size 48
set Status_wait 5000
proc ui {} {
  global My_fonts Config
  foreach f $My_fonts {
    eval font create $f [font configure TkDefaultFont]
    catch {font configure $f -size $Config($f)}
  }
 
  grid [label .title -textvariable State -anchor c -font title] -sticky ew
  # use "text" as geometry manager to facilitate reflowing buttons
  grid [text .t -height 2 -width 30 -bg white -state disabled] -sticky nsew
  grid [labelframe .data_frame -text "Current" -labelanchor n -font label] -sticky nsew
  grid [label .status -foreground red -textvariable Status -anchor c -font value] -sticky ew

  .t insert end " "
  .t window create end -window [button .playpause -text \u23ef -command {do pause}]
  .t window create end -window [button .softer    -text 🔈ᐁ -command {do volume -10}]
  .t window create end -window [button .louder    -text 🔊ᐃ -command {do volume +10}]
  .t window create end -window [button .prev      -text \u23ee -command {do previous}]
  .t window create end -window [button .next      -text \u23ed -command {do next}]
  .t window create end -window [button .shuffle   -text 🔀 -command toggle_random]
  .t window create end -window [menubutton .mb -text "playlist" -menu .mb.playlists]
  .t window create end -window \
	[labelframe .outputs -text "outputs" -labelanchor n -font label]
  .t window create end -window [button .exit -text 🛑 -command do_exit]
  .t insert end " "
  menu .mb.playlists -tearoff true -title "Playlists"

  foreach i [.t window names] {
    $i configure -font button
  }
  .mb configure -font label

  foreach i {Name Title Artist Album} {
    grid [label .l_$i -text $i -font label] \
         [label .i_$i -textvariable S($i) -font value] \
         -sticky ew -in .data_frame
  }

  grid columnconfigure . .data_frame -weight 1
  grid rowconfigure  . .data_frame -weight 1
  grid rowconfigure .data_frame .i_Title -weight 1

  grid columnconfigure . .t  -weight 1

  # wm attributes . -fullscreen 1
  catch {sdltk textinput off}
}

# set title wraplength dynamically
# bind .data_frame <Configure> title_width

proc title_width {} {
  lassign [grid bbox .data_frame 0 0] x x label_width x
  lassign [grid bbox .] x x width x
  incr width -$label_width
  incr width -5
  set was [.i_Title  cget -wraplength]
  if {$was != $width} {
    after idle ".i_Title configure -wraplength $width"
  }
}

proc update_state {a v w} {
  global S State
  if {$S(command) == "idle"} {
     set_state
  }
}

# Generate the current status line from S(*)
proc set_state {} {
  global S State
    if {![info exists S(song)]} {set S(song) 0}
    if {![info exists S(volume)]} {
      set vol n/a
    } else {
      set vol [format "%3d%%" $S(volume)]
    }
    array set map {pause paused play playing stop stopping}
    set State \
      "Track [incr S(song)]/$S(playlistlength) volume $vol \[$map($S(state))\]"
    if {$S(random)} {
      append State " shuffled"
    }
  # wm title . $State
  # .title configure -text $State
}

set Status_count 0
proc set_status {args} {
  global Status Status_count
  incr Status_count
  set Status {*}$args
  after [status_delay] "reset_status $Status_count"
}

proc reset_status {count} {
  global Status Status_count
  if {$count == $Status_count} {
     set Status -
  }
}

# longer status messages stay up longer
proc status_delay {} {
  global Status Status_wait
  if {[string length "$Status"] < 10} {
    return [expr $Status_wait / 2]
  }
  return $Status_wait
}

proc update_channels {} {
  global Channels
  # doesn't go here
  .mb.playlists delete 0 end
  foreach i [lsort $Channels] {
   .mb.playlists add command -label $i -command "do_playlist \$Socket $i"
  }
  unset Channels
}

# Create a control for each available output
# - Assume outputs don't change after initialization
# - No controls created if only one output is available
proc create_outputs {} {
    global Outputs Enabled
    if {[array size Outputs] < 2} return
    set col 0
    foreach {i name} [array get Outputs] {
      set c [checkbutton .o_$i -text $name -variable Enabled($i) \
             -command "do toggleoutput $i" -font label]
      grid $c -in .outputs -row 0 -column $col
      incr col
    }
}

proc clear_fields {{root .} {dflt -}} {
  global S
  foreach w [winfo children $root] {
    catch {
      set tv [$w cget -textvariable]
      if {$tv ne ""} {
        set $tv "-"
      }
    }
  }
}

# Toggle random play
proc toggle_random {} {
  global S
  array set random {1 0 0 1}
  set new $random($S(random))
  do random $new
  set S(random) $new
}
  
# send a command to the mpd daemon
proc do {args} {
  global Socket
  set_status "$args"
  m_command $Socket "$args"
}

# allow us to re-source for debugging
proc reset {} {
  global socket My_fonts
  catch {close $Socket}
  foreach w [winfo children .] {
    catch {grid forget $w}
    destroy $w
  }
  foreach font $My_fonts {
    font delete $font
  }
}

# Set the row size containing the controls
proc text_sync {sync} {
  if {$sync} {
    set y [.t count -ypixels 1.0 end]
    grid rowconfigure . .t  -minsize $y
  }
}

proc help {} {
  array set help {
    .playpause "Toggle between play and pause"
    .softer "Reduce volume"
    .louder "Increase volume"
    .prev "Go to previous track in playlist"
    .next "Go to next track in playlist"
    .shuffle "Toggle track shuffle mode"
    .mb "Select a playlist"
    .exit "Exit"
    .title "Status of currenly playing track"
    .outputs "Select audio output channels"
  }
  foreach {n v} [array get help] {
    bind $n <Enter> [list set Status $v]
    bind $n <Leave> "set Status -"
  }
}

proc read_config {name} {
  global Config
  if {![catch [list open $name] f]} {
    array set Config [read $f]
    debug "config: [array get Config]"
    close $f
  }
}

proc write_config {name} {
  global Config
  if {![catch [list open $name w] f]} {
    set Config(version) 0.2
    set Config(saved) [clock format [clock seconds] -format "%D-%T"]
    puts -nonewline $f [array get Config]
    close $f
  }
}

proc font_helper {win i} {
  global My_fonts
  set f none
  catch {set f [$win cget -font]}
  if {[lsearch -exact $My_fonts $f] >=0} {
    adjust_font $f $i
  }
}

proc adjust_font {name i} {
  global Config Min_font_size Max_font_size
  set s [font configure $name -size]
  incr s $i
  if {$s < $Min_font_size} {
    set_status "$name font already at minimum size ($Min_font_size)"
    return
  }
  if {$s > $Max_font_size} {
    set_status "$name font already at maximum size ($Max_font_size)"
    return
  }
  font configure $name -size $s
  set Config($name) $s
  update
}

proc do_exit {} {
  debug "Exiting!"
  write_config "~/.mui_tclrc"
  exit
}

read_config "~/.mui_tclrc"
start_ui
start_service
bind . <Key-Break> "borg withdraw"
catch {console hide}
bind .t <<WidgetViewSync>> "text_sync %d"
bind . <MouseWheel> "font_helper %W %D"
wm protocol . WM_DELETE_WINDOW {
    do_exit
}
