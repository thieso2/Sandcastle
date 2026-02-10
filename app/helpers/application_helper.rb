module ApplicationHelper
  def human_bytes(bytes)
    return "0 B" if bytes.nil? || bytes == 0

    units = %w[B KB MB GB TB]
    exp = (Math.log(bytes) / Math.log(1024)).to_i
    exp = [exp, units.length - 1].min
    value = bytes.to_f / (1024**exp)

    if value >= 10 || exp == 0
      "#{value.round(0)} #{units[exp]}"
    else
      "#{value.round(1)} #{units[exp]}"
    end
  end
end
