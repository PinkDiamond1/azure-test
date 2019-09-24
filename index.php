<?php
  $lines=explode("\n", file_get_contents('/proc/meminfo'));
  $meminfo=array();
  foreach ($lines as $line) {
    list($key,$value)=explode(':', trim($line));
    $meminfo[trim($key)]=floor(((int)trim($value))/1024);
  }
?>

<html>
  <head> 
  </head>
  <body style="text-align:center;">
    <p>
      <img style="width:498px; height:96px; margin:16px;" src="data:image/png;base64,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">
      <img style="width:194px; height:96px; margin:16px;" src="data:image/png;base64,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">
    </p>
    <p>Total memory: <?php echo $meminfo['MemTotal']; ?> MB</p>
    <p>Free memory: <?php echo $meminfo['MemFree']; ?> MB</p>
    <p>Available memory: <?php echo $meminfo['MemAvailable']; ?> MB</p>
  </body>
</html>
