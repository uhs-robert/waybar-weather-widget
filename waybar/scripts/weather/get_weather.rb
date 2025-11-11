#!/usr/bin/env ruby
# waybar/scripts/weather/get_weather.rb
# frozen_string_literal: true

# Waybar weather (Open-Meteo.com)
# - Text: current temp + icon (colored via <span>)
# - Tooltip: current details + next N hours table + up to 16-day table
# - Uses weather_icons.json mapping for WMO condition glyphs
# - Emits Waybar JSON (set return-type=json, markup=true)

require 'json'
require 'set'
require 'net/http'
require 'uri'
require 'time'
require 'cgi'
require 'fileutils'

# ─── Constants ──────────────────────────────────────────────────────────────
SEASONAL_BIAS = ENV.fetch('SEASONAL_BIAS', '1') == '1'
POP_ALERT_THRESHOLD = 60
DIVIDER_CHAR = '─'
DIVIDER_LEN = 74

ICON = {
  THERMOMETER: {
    COLD: '',
    NEUTRAL: '',
    WARM: '',
    HOT: ''
  },

  SUN: {
    RISE: '',
    SET: '󰖚'
  },

  PRECIPITATION: {
    LOW: '',
    HIGH: ''
  }
}.freeze

# Table headers
HOUR_TABLE_HEADER_TEXT = format(
  '%<hr>-4s │ %<temp>5s │ %<pop>4s │ %<precip>7s │ Cond',
  hr: 'Hr', temp: 'Temp', pop: 'PoP', precip: 'Precip'
)
DAY_TABLE_HEADER_TEXT = format(
  '%-<day>9s │ %<hi>5s │ %<lo>5s │ %<pop>4s │ %<precip>7s │ Cond',
  day: 'Day', hi: 'Hi', lo: 'Lo', pop: 'PoP', precip: 'Precip'
)

DETAIL3H_HEADER_TEXT = format(
  '%-<date>9s │ %<hr>2s │ %<temp>5s │ %<pop>4s │ %<precip>7s │ Cond',
  date: 'Date', hr: 'Hr', temp: 'Temp', pop: 'PoP', precip: 'Precip'
)

ASTRO3D_HEADER_TEXT = format(
  '%-<date>9s │ %<rise>5s │ %<set>5s',
  date: 'Date', rise: 'Rise', set: 'Set'
)

# WMO Weather code descriptions
WMO_CODE_DESCRIPTIONS = {
  0 => 'Clear sky',
  1 => 'Mainly clear',
  2 => 'Partly cloudy',
  3 => 'Overcast',
  45 => 'Fog',
  48 => 'Depositing rime fog',
  51 => 'Light drizzle',
  53 => 'Moderate drizzle',
  55 => 'Dense drizzle',
  56 => 'Light freezing drizzle',
  57 => 'Dense freezing drizzle',
  61 => 'Slight rain',
  63 => 'Moderate rain',
  65 => 'Heavy rain',
  66 => 'Light freezing rain',
  67 => 'Heavy freezing rain',
  71 => 'Slight snow fall',
  73 => 'Moderate snow fall',
  75 => 'Heavy snow fall',
  77 => 'Snow grains',
  80 => 'Slight rain showers',
  81 => 'Moderate rain showers',
  82 => 'Violent rain showers',
  85 => 'Slight snow showers',
  86 => 'Heavy snow showers',
  95 => 'Thunderstorm',
  96 => 'Thunderstorm with slight hail',
  99 => 'Thunderstorm with heavy hail'
}.freeze

# ─── Modules ────────────────────────────────────────────────────────────────

# Main configuration, merges with user config for dynamic user settings based on json file
module Config
  @settings = {
    colors: {
      'primary' => '#42A5F5',
      'cold' => 'skyblue',
      'neutral' => '#42A5F5',
      'warm' => 'khaki',
      'hot' => 'indianred',
      'pop_low' => '#EAD7FF',
      'pop_med' => '#CFA7FF',
      'pop_high' => '#BC85FF',
      'pop_vhigh' => '#A855F7',
      'divider' => '#2B3B57'
    },
    icon_type: 'nerd_font', # 'nerd_font' | 'emoji'
    icon_position: 'left', # 'left' | 'right'
    font_size: 14, # in px
    unit: 'Celsius', # 'Celsius' | 'Fahrenheit'
    hours_ahead: 24, # max 24
    forecast_days: 10, # max 16
    pongo_size: {}
  }

  SETTING_KEY_MAP = {
    'icon_type' => :icon_type,
    'icon_position' => :icon_position,
    'font_size' => :font_size,
    'unit' => :unit,
    'hours_ahead' => :hours_ahead,
    'forecast_days' => :forecast_days
  }.freeze

  def self.settings
    @settings
  end

  def self.init(user_config)
    # Merge colors settings
    @settings[:colors].merge!(user_config['colors']) if user_config.key?('colors') && user_config['colors'].is_a?(Hash)

    # Handle font size calculations
    self.set_font_size = user_config['font_size'] if user_config.key?('font_size')

    # Merge other settings
    SETTING_KEY_MAP.each do |config_key, settings_key|
      @settings[settings_key] = user_config[config_key] if user_config.key?(config_key)
    end
  end

  def self.colors
    @settings[:colors]
  end

  def self.pongo_size
    @settings[:pongo_size]
  end

  def self.icon_set
    @settings[:icon_type]
  end

  def self.set_color(key, value)
    @settings[:colors][key] = value
  end

  def self.set_font_size=(value)
    @settings[:font_size] = value
    update_pongo_sizes
  end

  private_class_method def self.update_pongo_sizes
    current_size = @settings[:font_size]
    @settings[:pongo_size] = {
      small: (current_size - 2) * 1000,
      medium: current_size * 1000,
      large: (current_size + 4) * 1000
    }
  end

  update_pongo_sizes
end

# Parses temperature into glyphs and colors
module Temperature
  SUMMER_MONTHS = (5..9).freeze
  SHOULDER_MONTHS = [3, 4, 10].freeze
  DEFAULT_COLD_C = 5
  DEFAULT_COLD_F = 41
  COLD_BAND    = [ICON[:THERMOMETER][:COLD], Config.colors['cold']].freeze
  NEUTRAL_BAND = [ICON[:THERMOMETER][:NEUTRAL], Config.colors['neutral']].freeze
  WARM_BAND    = [ICON[:THERMOMETER][:WARM], Config.colors['warm']].freeze
  HOT_BAND     = [ICON[:THERMOMETER][:HOT], Config.colors['hot']].freeze

  def self.init(unit:, bias:, month: Time.now.month)
    @unit = unit
    @seasonal_bias_enabled = bias
    @current_month = month
    @temperature_bands = build_temperature_bands
  end

  def self.glyph_and_color(temp)
    found_band = @temperature_bands.find do |limit, _glyph, _color|
      temp < limit
    end
    return nil if found_band.nil?

    [found_band[1], found_band[2]]
  end

  def self.color(temp)
    glyph_and_color = glyph_and_color(temp)
    return unless glyph_and_color

    glyph_and_color.last
  end

  def self.glyph(temp)
    glyph_and_color = glyph_and_color(temp)
    return unless glyph_and_color

    glyph_and_color.first
  end

  # --- Private Helpers ---
  private_class_method def self.build_temperature_bands
    cold, neutral, warm = temperature_limits

    [
      [cold, *COLD_BAND],
      [neutral, *NEUTRAL_BAND],
      [warm,    *WARM_BAND],
      [Float::INFINITY, *HOT_BAND]
    ]
  end

  private_class_method def self.temperature_limits
    cold_limit = calculate_cold_limit

    if celsius?
      [cold_limit, 20, 28]
    else
      [cold_limit, 68, 82]
    end
  end

  private_class_method def self.calculate_cold_limit
    unless @seasonal_bias_enabled
      return celsius? ? DEFAULT_COLD_C : DEFAULT_COLD_F
    end

    if celsius?
      calculate_seasonal_celsius_cold_limit
    else
      calculate_seasonal_fahrenheit_cold_limit
    end
  end

  private_class_method def self.calculate_seasonal_celsius_cold_limit
    return 10 if SUMMER_MONTHS.cover?(@current_month)
    return 8 if SHOULDER_MONTHS.include?(@current_month)

    DEFAULT_COLD_C
  end

  private_class_method def self.calculate_seasonal_fahrenheit_cold_limit
    celsius_limit = calculate_seasonal_celsius_cold_limit
    ((celsius_limit * 9.0 / 5.0) + 32).round
  end

  private_class_method def self.celsius?
    @unit.to_s.strip.start_with?('°C')
  end
end

# ─── Utilities ──────────────────────────────────────────────────────────────
def safe(hash, key, default = nil)
  hash.key?(key) ? hash[key] : default
end

def load_json(path)
  file_content = File.read(path, encoding: 'utf-8')
  # Basic JSONC support: remove single-line comments
  content_no_comments = file_content.gsub(%r{//.*$}, '')
  JSON.parse(content_no_comments)
end

def divider(length = DIVIDER_LEN, char = DIVIDER_CHAR, color = Config.colors['divider'])
  line = char * [1, length].max
  "<span font_family='monospace' foreground='#{color}'>#{line}</span>"
end

def parse_int(val, default = 0)
  return default if val.nil? || val == ''
  return val.to_i if val.is_a?(Numeric)
  return val.to_i if val.to_s.match?(/\A-?\d+\z/)
  return val.to_f.to_i if val.to_s.match?(/\A-?\d+\.?\d*\z/)

  default
end

def parse_float(val, default = 0.0)
  return default if val.nil? || val == ''
  return val.to_f if val.is_a?(Numeric)
  return val.to_f if val.to_s.match?(/\A-?\d+\.?\d*\z/)

  default
end

def fmt_hour(datetime)
  datetime.strftime('%H')
end

def fmt_day_of_week(datestr)
  # e.g., 'Mon 10/06'
  Time.strptime(datestr, '%Y-%m-%d').strftime('%a %m/%d')
end

def pop_color(pop)
  pop = [[0, pop.to_i].max, 100].min
  return Config.colors['pop_low'] if pop < 30    # 0–29
  return Config.colors['pop_med'] if pop < 60    # 30–59
  return Config.colors['pop_high'] if pop < 80   # 60–79

  Config.colors['pop_vhigh'] # 80–100
end

def icon_for_pop(pop)
  pop >= POP_ALERT_THRESHOLD ? ICON[:PRECIPITATION][:HIGH] : ICON[:PRECIPITATION][:LOW]
end

def wmo_code_description(code)
  WMO_CODE_DESCRIPTIONS[code.to_i] || 'Unknown'
end

def mode_file
  state_home = ENV['XDG_STATE_HOME'] || File.expand_path('~/.local/state')
  dir = File.join(state_home, 'waybar')
  FileUtils.mkdir_p(dir)
  File.join(dir, 'weather_mode')
end

def get_mode
  mode = File.read(mode_file, encoding: 'utf-8').strip
  %w[default weekview].include?(mode) ? mode : 'default'
rescue Errno::ENOENT
  'default'
end

def set_mode(mode)
  File.write(mode_file, mode, encoding: 'utf-8')
end

def cycle_mode(direction = 'next')
  modes = %w[default weekview]
  cur = get_mode
  i = modes.index(cur) || 0
  i = direction == 'prev' ? (i - 1) % modes.length : (i + 1) % modes.length
  set_mode(modes[i])
end

# ─── Icons ──────────────────────────────────────────────────────────────────
def load_icon_map(script_path)
  data = load_json(File.join(script_path, 'weather_icons.json'))
  data.is_a?(Array) ? data : []
rescue StandardError
  []
end

def norm(str)
  str.to_s.strip.downcase
end

def to_set(val)
  return Set.new if val.nil?
  return Set.new(val.map { |x| norm(x) }) if val.is_a?(Array)

  Set[norm(val)]
end

def map_condition_icon(icon_map, code, is_day)
  code = code.to_i

  # Find exact code match
  icon_map.each do |item|
    next unless item['code'].to_i == code

    return is_day ? (item['icon'] || '') : (item['icon-night'] || '')
  end

  ''
end

def style_icon(glyph, color = Config.colors['primary'], size = Config.pongo_size[:medium])
  "<span foreground='#{color}' size='#{size}'>#{glyph} </span>"
end

# ─── Data fetch / parse ─────────────────────────────────────────────────────
def fetch_location_from_ip
  # Use ip-api.com for free IP geolocation (no API key required)
  # Rate limit: 45 requests/minute
  url = URI('http://ip-api.com/json/?fields=lat,lon,city,regionName,country')

  response = Net::HTTP.get_response(url)
  raise "IP geolocation error: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  data = JSON.parse(response.body)
  raise 'Unexpected response from ip-api.com' unless data.is_a?(Hash)

  {
    'lat' => parse_float(data['lat']),
    'lon' => parse_float(data['lon']),
    'location_name' => "#{data['city']}, #{data['regionName']}, #{data['country']}"
  }
end

def load_config(script_path)
  cfg_path = File.join(script_path, 'weather_settings.jsonc')
  data = load_json(cfg_path)
  raise 'weather_settings.jsonc must be a JSON object' unless data.is_a?(Hash)

  data
end

def fetch_openmeteo_forecast(lat, lon, unit_c, forecast_days = 16)
  url = URI('https://api.open-meteo.com/v1/forecast')

  params = {
    latitude: lat,
    longitude: lon,
    current: 'temperature_2m,apparent_temperature,is_day,precipitation,weather_code',
    hourly: 'temperature_2m,precipitation_probability,precipitation,weather_code,is_day',
    daily: 'weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,sunrise,sunset',
    temperature_unit: unit_c ? 'celsius' : 'fahrenheit',
    precipitation_unit: unit_c ? 'mm' : 'inch',
    timezone: 'auto',
    forecast_days: forecast_days
  }
  url.query = URI.encode_www_form(params)

  response = Net::HTTP.get_response(url)
  raise "HTTP Error: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  data = JSON.parse(response.body)
  raise 'Unexpected response from Open-Meteo' unless data.is_a?(Hash)

  data
end

def extract_current(blob, _unit, location_name = nil)
  cur = blob['current']
  timezone = blob['timezone']

  # Parse current time in the location's timezone
  now_local = Time.parse(cur['time'])

  {
    'timezone' => timezone,
    'location_name' => location_name,
    'cond' => wmo_code_description(cur['weather_code']),
    'code' => cur['weather_code'].to_i,
    'temp' => parse_float(cur['temperature_2m']),
    'feels' => parse_float(cur['apparent_temperature']),
    'precip_amt' => parse_float(cur['precipitation']),
    'is_day' => parse_int(cur['is_day'], 1),
    'now_local' => now_local
  }
end

def build_next_hours(blob, now_local, limit)
  hourly = blob['hourly']
  times = hourly['time']
  temps = hourly['temperature_2m']
  pops = hourly['precipitation_probability']
  precips = hourly['precipitation']
  codes = hourly['weather_code']
  is_days = hourly['is_day']

  hours_list = []

  times.each_with_index do |time_str, i|
    dt = Time.parse(time_str)

    hours_list << {
      'dt' => dt,
      'temp' => parse_float(temps[i]),
      'pop' => parse_int(pops[i]),
      'precip' => parse_float(precips[i]),
      'cond' => wmo_code_description(codes[i]),
      'code' => codes[i].to_i,
      'is_day' => parse_int(is_days[i], 1)
    }
  end

  next_hours = hours_list.select { |h| h['dt'] >= now_local }[0, [0, limit].max]
  next_hours = hours_list[0, [0, limit].max] if next_hours.empty? && !hours_list.empty?
  next_hours
end

def build_next_days(blob, max_days = 16)
  daily = blob['daily']
  dates = daily['time']
  max_temps = daily['temperature_2m_max']
  min_temps = daily['temperature_2m_min']
  codes = daily['weather_code']
  precips = daily['precipitation_sum']
  pops = daily['precipitation_probability_max']
  sunrises = daily['sunrise']
  sunsets = daily['sunset']

  days = []

  dates[0...max_days].each_with_index do |date_str, i|
    days << {
      'date' => date_str,
      'max' => parse_float(max_temps[i]),
      'min' => parse_float(min_temps[i]),
      'cond' => wmo_code_description(codes[i]),
      'code' => codes[i].to_i,
      'precip' => parse_float(precips[i]),
      'pop' => parse_int(pops[i]),
      'sunrise' => sunrises[i],
      'sunset' => sunsets[i]
    }
  end

  days
end

def build_next_3days_detailed(blob, now_local, num_days = 3)
  hourly = blob['hourly']
  times = hourly['time']
  temps = hourly['temperature_2m']
  pops = hourly['precipitation_probability']
  precips = hourly['precipitation']
  codes = hourly['weather_code']
  is_days = hourly['is_day']

  today = now_local.strftime('%Y-%m-%d')

  rows = []
  picked_dates = Set.new

  times.each_with_index do |time_str, i|
    dt = Time.parse(time_str)
    date_str = dt.strftime('%Y-%m-%d')

    # Skip today and past dates
    next if date_str <= today

    # Only process 3-hour intervals
    next unless (dt.hour % 3).zero?

    picked_dates << date_str

    # Stop when we have enough days
    break if picked_dates.size > num_days

    rows << {
      'date' => date_str,
      'dt' => dt,
      'temp' => parse_float(temps[i]),
      'pop' => parse_int(pops[i]),
      'precip' => parse_float(precips[i]),
      'cond' => wmo_code_description(codes[i]),
      'code' => codes[i].to_i,
      'is_day' => parse_int(is_days[i], 1)
    }
  end

  rows.sort_by { |r| [r['date'], r['dt']] }
end

def build_astro_by_date(days)
  # Map 'YYYY-MM-DD' -> [sunrise_24h, sunset_24h]
  out = {}
  days.each do |d|
    date_str = d['date']
    sr = d['sunrise'] ? Time.parse(d['sunrise']).strftime('%H:%M') : ''
    ss = d['sunset'] ? Time.parse(d['sunset']).strftime('%H:%M') : ''
    out[date_str] = [sr, ss]
  end
  out
end

def get_sun_times(days, now_local)
  today = now_local.strftime('%Y-%m-%d')
  days.each do |d|
    next unless d['date'] == today

    sr = d['sunrise'] ? Time.parse(d['sunrise']).strftime('%H:%M') : ''
    ss = d['sunset'] ? Time.parse(d['sunset']).strftime('%H:%M') : ''
    return [sr, ss]
  end
  ['', '']
end

def make_astro3d_table(rows, astro_by_date)
  # Build a compact table for sunrise/sunset for the dates present in rows.
  header = "<span weight='bold'>#{ASTRO3D_HEADER_TEXT}</span>"
  dates = rows.map { |r| r['date'].to_s }.uniq.sort
  lines = dates.map do |date|
    sr, ss = astro_by_date.fetch(date, ['', ''])
    sr = (sr.empty? ? '—' : sr)[0, 5]
    ss = (ss.empty? ? '—' : ss)[0, 5]
    format('%-9s │ %5s │ %5s', fmt_day_of_week(date), sr, ss)
  end

  return 'No sunrise/sunset data' if lines.empty?

  "<span font_family='monospace'>#{header}\n#{lines.join("\n")}</span>"
end

# ─── Tables & Tooltip ───────────────────────────────────────────────────────
def make_hour_table(next_hours, unit, precip_unit, icon_map)
  header = "<span weight='bold'>#{HOUR_TABLE_HEADER_TEXT}</span>"
  rows = []

  next_hours.each do |h|
    temp_txt = "#{h['temp'].round}#{unit}".rjust(5)
    # temp_col = "<span foreground='#{color_for_temp(h['temp'], unit)}'>#{temp_txt}</span>"
    temp_col = "<span foreground='#{Temperature.color(h['temp'])}'>#{temp_txt}</span>"

    pop_txt = "#{h['pop'].to_i}%".rjust(4)
    pop_col = "<span foreground='#{pop_color(h['pop'])}'>#{pop_txt}</span>"

    precip_col = format('%<val>.1f %<unit>s', val: h['precip'], unit: precip_unit).rjust(7)

    glyph = map_condition_icon(icon_map, h['code'], h['is_day'] != 0)
    icon_html = glyph.empty? ? '' : style_icon(glyph, Config.colors['primary'], Config.pongo_size[:small])
    cond_cell = "#{icon_html} #{CGI.escapeHTML(h['cond'].to_s)}".strip

    rows << format('%-4s │ %s │ %s │ %s │ %s',
                   fmt_hour(h['dt']), temp_col, pop_col, precip_col, cond_cell)
  end

  return 'No hourly data' if rows.empty?

  "<span font_family='monospace'>#{header}\n#{rows.join("\n")}</span>"
end

def make_day_table(days, unit, precip_unit, icon_map)
  header = "<span weight='bold'>#{DAY_TABLE_HEADER_TEXT}</span>"
  out_rows = []

  days.each do |d|
    hi_val = d['max'].round
    lo_val = d['min'].round

    hi_txt = format('%3d%s', hi_val, unit)
    lo_txt = format('%3d%s', lo_val, unit)

    hi_col = "<span foreground='#{Temperature.color(d['max'])}'>#{hi_txt}</span>"
    lo_col = "<span foreground='#{Temperature.color(d['min'])}'>#{lo_txt}</span>"

    pop = [[0, d['pop'].to_i].max, 100].min
    pop_txt = format('%3d%%', pop)
    pop_col = "<span foreground='#{pop_color(pop)}'>#{pop_txt}</span>"

    precip_col = format('%<val>.1f %<unit>s', val: d['precip'], unit: precip_unit).rjust(7)

    cond_txt = d['cond'].to_s
    glyph = map_condition_icon(icon_map, d['code'], true)
    icon_html = glyph.empty? ? '' : style_icon(glyph, Config.colors['primary'], Config.pongo_size[:small])
    cond_cell = "#{icon_html} #{CGI.escapeHTML(cond_txt)}".strip

    row = format('%-9s │ %s │ %s │ %s │ %s │ %s',
                 fmt_day_of_week(d['date']), hi_col, lo_col, pop_col, precip_col, cond_cell)
    out_rows << row
  end

  return 'No daily data' if out_rows.empty?

  "<span font_family='monospace'>#{header}\n#{out_rows.join("\n")}</span>"
end

def make_3h_table(rows, unit, precip_unit, icon_map)
  header = "<span weight='bold'>#{DETAIL3H_HEADER_TEXT}</span>"
  out = []

  rows.each do |r|
    temp_txt = "#{r['temp'].round}#{unit}".rjust(5)
    temp_col = "<span foreground='#{Temperature.color(r['temp'])}'>#{temp_txt}</span>"

    pop_val = [[0, r['pop'].to_i].max, 100].min
    pop_txt = format('%3d%%', pop_val)
    pop_col = "<span foreground='#{pop_color(pop_val)}'>#{pop_txt}</span>"

    precip_col = format('%<val>.1f %<unit>s', val: r['precip'], unit: precip_unit).rjust(7)

    glyph = map_condition_icon(icon_map, r['code'], r['is_day'] != 0)
    icon_html = glyph.empty? ? '' : style_icon(glyph, Config.colors['primary'], Config.pongo_size[:small])
    cond_cell = "#{icon_html} #{CGI.escapeHTML(r['cond'].to_s)}".strip

    out << format('%-9s │ %2s │ %s │ %s │ %s │ %s',
                  fmt_day_of_week(r['date']), fmt_hour(r['dt']), temp_col, pop_col, precip_col, cond_cell)
  end

  return 'No 3-hour detail' if out.empty?

  "<span font_family='monospace'>#{header}\n#{out.join("\n")}</span>"
end

def build_header_block(timezone:, cond:, temp:, feels:, unit:, icon_map:, code:, is_day:, fallback_icon:,
                       sunrise: nil, sunset: nil, now_pop: nil, precip_amt: nil, precip_unit: '', location_name: nil)
  # Returns the exact same top block used by all tooltips.
  display_location = location_name || timezone || 'Local'
  location_line = format('<b>%s</b>', CGI.escapeHTML(display_location))

  # current conditions + colored thermometer
  tglyph, tcolor = Temperature.glyph_and_color(feels)
  current_line = format('%s %s | %s%d%s (feels %d%s)',
                        style_icon(map_condition_icon(icon_map, code, is_day != 0) || fallback_icon),
                        CGI.escapeHTML(cond),
                        style_icon(tglyph, tcolor),
                        temp.round,
                        unit,
                        feels.round,
                        unit)

  # optional sunrise/sunset
  astro_line = ''
  if sunrise || sunset
    astro_line = format('%s Sunrise %s | %s Sunset %s',
                        style_icon(ICON[:SUN][:RISE]),
                        CGI.escapeHTML(sunrise || '—'),
                        style_icon(ICON[:SUN][:SET]),
                        CGI.escapeHTML(sunset || '—'))
  end

  # optional "now" precip / PoP (colored)
  now_line = ''
  if now_pop && precip_amt && !precip_unit.empty?
    pop_icon_html = style_icon(icon_for_pop(now_pop), pop_color(now_pop))
    now_pop_col = "<span foreground='#{pop_color(now_pop)}'>#{now_pop.to_i}%</span>"
    now_line = format('%s PoP %s, Precip %.1f%s',
                      pop_icon_html, now_pop_col, precip_amt, precip_unit)
  end

  parts = [location_line, '', current_line]
  parts << astro_line unless astro_line.empty?
  parts << now_line unless now_line.empty?
  parts << "\n#{divider}\n"
  parts.join("\n")
end

def build_week_view_tooltip(timezone:, cond:, temp:, feels:, unit:, icon_map:, code:, is_day:, fallback_icon:,
                            three_hour_rows:, precip_unit:, sunrise: nil, sunset: nil,
                            now_pop: nil, precip_amt: nil, astro_by_date: nil, location_name: nil)
  header_block = build_header_block(
    timezone: timezone, cond: cond, temp: temp, feels: feels, unit: unit,
    icon_map: icon_map, code: code, is_day: is_day, fallback_icon: fallback_icon,
    sunrise: sunrise, sunset: sunset, now_pop: now_pop,
    precip_amt: precip_amt, precip_unit: precip_unit, location_name: location_name
  )

  astro_table = make_astro3d_table(three_hour_rows, astro_by_date || {})
  astro_header = "<b>#{style_icon(ICON[:SUN][:RISE], Config.colors['primary'],
                                  Config.pongo_size[:small])} Week Sunrise / Sunset</b>"

  detail_header = "<b>#{style_icon('󰨳', Config.colors['primary'], Config.pongo_size[:small])} Week Details</b>"
  detail_table = make_3h_table(three_hour_rows, unit, precip_unit, icon_map)

  "#{header_block}\n#{astro_header}\n\n#{astro_table}\n\n#{divider}\n\n#{detail_header}\n\n#{detail_table}"
end

def build_text_and_tooltip(timezone:, cond:, temp:, feels:, precip_amt:, code:, is_day:, next_hours:,
                           days:, unit:, precip_unit:, icon_map:, icon_pos:, fallback_icon:,
                           sunrise:, sunset:, location_name: nil, forecast_days: 16)
  # icon for current condition
  cond_icon_raw = map_condition_icon(icon_map, code, is_day != 0) || fallback_icon

  # main text with waybar icon
  waybar_icon = style_icon(cond_icon_raw, Config.colors['primary'], Config.pongo_size[:small])
  left = "#{waybar_icon}#{temp.round}#{unit}"
  right = "#{temp.round}#{unit} #{waybar_icon}"
  text = (icon_pos || 'left') == 'left' ? left : right

  # tables
  next_hours_table = make_hour_table(next_hours, unit, precip_unit, icon_map)
  next_days_overview_table = make_day_table(days, unit, precip_unit, icon_map)

  header_block = build_header_block(
    timezone: timezone, cond: cond, temp: temp, feels: feels, unit: unit,
    icon_map: icon_map, code: code, is_day: is_day, fallback_icon: fallback_icon,
    sunrise: sunrise, sunset: sunset,
    now_pop: next_hours.empty? ? nil : next_hours[0]['pop'].to_i,
    precip_amt: precip_amt, precip_unit: precip_unit, location_name: location_name
  )

  tooltip = "#{header_block}\n" \
            "<b>#{style_icon('', Config.colors['primary'],
                             Config.pongo_size[:small])} Next #{next_hours.length} hours</b>\n\n" \
            "#{next_hours_table}\n\n#{divider}\n\n" \
            "<b>#{style_icon('󰨳', Config.colors['primary'],
                             Config.pongo_size[:small])} Next #{forecast_days} Days</b>\n\n#{next_days_overview_table}"
  [text, tooltip]
end

# ─── Main runner ────────────────────────────────────────────────────────────
def main
  # quick mode ops (no network)
  if ARGV.length > 0
    arg = ARGV[0]
    if %w[--next --toggle].include?(arg)
      cycle_mode('next')
      return
    elsif arg == '--prev'
      cycle_mode('prev')
      return
    elsif arg == '--set' && ARGV.length > 1
      set_mode(ARGV[1])
      return
    end
  end

  script_path = __dir__

  begin
    cfg = load_config(script_path)
    mode = get_mode
    Config.init(cfg)

    # Parse config
    unit_c = Config.settings[:unit] == 'Celsius'
    hours_ahead = (Config.settings[:hours_ahead] || 24).to_i
    forecast_days = (Config.settings[:forecast_days] || 16).to_i
    icon_pos = (Config.settings[:icon_position] || 'left').to_s
    unit = unit_c ? '°C' : '°F'
    precip_unit = unit_c ? 'mm' : 'in'

    # Init Temperature
    Temperature.init(
      unit: unit,
      bias: SEASONAL_BIAS,
      month: Time.now.month
    )

    # Detect location
    lat_cfg = cfg['latitude'].to_s.strip.downcase
    lon_cfg = cfg['longitude'].to_s.strip.downcase
    location_name = nil

    if lat_cfg == 'auto' || lon_cfg == 'auto'
      # Fetch location from IP
      geo_data = fetch_location_from_ip
      lat = geo_data['lat']
      lon = geo_data['lon']
      location_name = geo_data['location_name']
    else
      # Use hardcoded coordinates
      lat = parse_float(cfg['latitude'])
      lon = parse_float(cfg['longitude'])
    end

    # data
    blob = fetch_openmeteo_forecast(lat, lon, unit_c, forecast_days)
    cur = extract_current(blob, unit, location_name)
    next_hours = build_next_hours(blob, cur['now_local'], hours_ahead)
    days = build_next_days(blob, forecast_days)
    next_3days_detailed = build_next_3days_detailed(blob, cur['now_local'], 3)
    sunrise, sunset = get_sun_times(days, cur['now_local'])
    astro_by_date = build_astro_by_date(days)

    # icons
    icon_map = load_icon_map(script_path)
    fallback_icon = map_condition_icon(icon_map, cur['code'], cur['is_day'] != 0) || ''

    # Default tooltip (compact)
    text_default, tooltip_default = build_text_and_tooltip(
      timezone: cur['timezone'], cond: cur['cond'], temp: cur['temp'], feels: cur['feels'],
      precip_amt: cur['precip_amt'], code: cur['code'], is_day: cur['is_day'], next_hours: next_hours,
      days: days, unit: unit, precip_unit: precip_unit, icon_map: icon_map,
      icon_pos: icon_pos, fallback_icon: fallback_icon, sunrise: sunrise, sunset: sunset,
      location_name: cur['location_name'], forecast_days: forecast_days
    )

    # Detail tooltip (3-hour view)
    tooltip_week_view = build_week_view_tooltip(
      timezone: cur['timezone'], cond: cur['cond'], temp: cur['temp'], feels: cur['feels'],
      unit: unit, icon_map: icon_map, code: cur['code'], is_day: cur['is_day'], fallback_icon: fallback_icon,
      three_hour_rows: next_3days_detailed, precip_unit: precip_unit,
      sunrise: sunrise, sunset: sunset,
      now_pop: next_hours.empty? ? nil : next_hours[0]['pop'].to_i,
      precip_amt: cur['precip_amt'], astro_by_date: astro_by_date,
      location_name: cur['location_name']
    )

    text = text_default
    tooltip = mode == 'weekview' ? tooltip_week_view : tooltip_default

    classes = [
      'weather',
      mode == 'weekview' ? 'mode-weekview' : 'mode-default',
      next_hours.any? && next_hours[0]['pop'].to_i >= 60 ? 'pop-high' : 'pop-low'
    ]

    out = {
      text: text,
      tooltip: tooltip,
      alt: cur['cond'],
      class: classes
    }

    puts JSON.generate(out)
  rescue Net::HTTPError, SocketError, Timeout::Error => e
    sleep 2
    puts JSON.generate(text: '…', tooltip: "network error: #{e.message}")
  rescue JSON::ParserError, KeyError => e
    puts JSON.generate(text: '', tooltip: "parse error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
  rescue StandardError => e
    puts JSON.generate(text: '!', tooltip: "unexpected error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
  end
end

main if __FILE__ == $PROGRAM_NAME
