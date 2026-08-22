-- Droplet: Dateien auf das App-Icon ziehen -> Upload ans reMarkable.
-- Die Platzhalter werden von install.sh ersetzt.

property pythonBin : "__PYTHON__"
property scriptPath : "__SCRIPT__"

on open theseItems
	set argList to ""
	repeat with anItem in theseItems
		set argList to argList & " " & quoted form of (POSIX path of anItem)
	end repeat
	try
		do shell script quoted form of pythonBin & " " & quoted form of scriptPath & argList
	on error errMsg
		display notification errMsg with title "reMarkable: Upload fehlgeschlagen"
	end try
end open

on run
	display dialog "Zieh Dateien auf dieses Icon, um sie an dein reMarkable zu schicken." & return & return & "PDF und EPUB gehen direkt, Office-Dokumente, Bilder und E-Books werden vorher konvertiert." buttons {"OK"} default button 1 with title "Send to reMarkable"
end run
