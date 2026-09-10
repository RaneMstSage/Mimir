# Thin wrappers over the native Inspect module so the rest of the app never touches JNI names.
module Host
  LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }

  # Send a command to the Java side (executed on the Android main thread).
  def self.emit(cmd, fields = {})
    Inspect.emit({ "cmd" => cmd }.merge(fields).to_json)
  end

  def self.log(level, msg)
    text = msg.to_s
    Inspect.log(LEVELS.fetch(level, 1), text)
    emit("log", "level" => level.to_s, "text" => text)
  end

  def self.toast(text)
    emit("toast", "text" => text.to_s)
  end
end
