<p align="center">
  <img
    src="https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/svg/1f326.svg"
    width="128" height="128" alt="Weather emoji" />
</p>
<h1 align="center">Waybar Weather Widget</h1>

<p align="center">
  <a href="https://github.com/uhs-robert/waybar-weather-widget/stargazers"><img src="https://img.shields.io/github/stars/uhs-robert/waybar-weather-widget?colorA=192330&colorB=skyblue&style=for-the-badge&cacheSeconds=4300"></a>
  <a href="https://github.com/uhs-robert/waybar-weather-widget/issues"><img src="https://img.shields.io/github/issues/uhs-robert/waybar-weather-widget?colorA=192330&colorB=khaki&style=for-the-badge&cacheSeconds=4300"></a>
  <a href="https://github.com/uhs-robert/waybar-weather-widget/contributors"><img src="https://img.shields.io/github/contributors/uhs-robert/waybar-weather-widget?colorA=192330&colorB=8FD1C7&style=for-the-badge&cacheSeconds=4300"></a>
  <a href="https://github.com/uhs-robert/waybar-weather-widget/network/members"><img src="https://img.shields.io/github/forks/uhs-robert/waybar-weather-widget?colorA=192330&colorB=C799FF&style=for-the-badge&cacheSeconds=4300"></a>
</p>

<p align="center">
A <strong>detailed and customizable</strong> weather widget for Waybar, powered by the Open-Meteo API.

</p>

<https://github.com/user-attachments/assets/32f5bb93-c096-41f1-a141-40ccaba9a1cc>

## ✨ Features

It provides current weather, hourly forecasts, and a multi-day forecast with a clean, icon-based display.

- **Current Weather:** Displays the current temperature and a weather icon for current conditions.
- **Geolocation:** Automatically detects your location via your IP address, or you can set a manual latitude/longitude.
- **Detailed Tooltips:**
  - **Default View:** Shows current details, an hourly forecast (default 12 hours, max 24), and a up to 16-day daily forecast.
  - **Week View:** Shows a detailed 3-hour interval forecast for the next few days, including sunrise and sunset times.
- **Customizable:**
  - Supports both Celsius and Fahrenheit.
  - Supports both 12-hour (AM/PM) and 24-hour time formats.
  - Uses Nerd Font icons or emoji for weather conditions.
  - All colors are customizable.
  - You can change the number of hours and days to forecast.
- **Dynamic Icons:** Weather icons change for day and night.
- **Command-line Interface:** A simple CLI to toggle between tooltip views.

## 📸 Screenshots

Features a tooltip with multiple modes that can be cycled through to view more weather data.

<table>
  <tr>
    <td align="center">
      <img src="./assets/screenshots/default_view.png" alt="Default" width="auto"><br>
      <strong>Default Tooltip</strong><br><em>Current Details, Hourly Forecast (12h default, 24h max), 16-Day Forecast</em>
    </td>
    <td align="center">
      <img src="./assets/screenshots/week_details.png" alt="Week Details" width="auto"><br>
      <strong>Week Details</strong><br><em>Current Details, Sunrise/Sunset Times, and 3-Hour Interval Snapshot over Next 3 Days</em>
    </td>
  </tr>
</table>

## ⬇️ Installation

1. **Clone the repository** or download the files into your `~/.config/waybar/` directory. Your structure should look something like this:

   ```
   ~/.config/waybar/
   ├── config.jsonc
   ├── style.css
   └── scripts/
       └── weather/
           ├── get_weather.rb
           ├── weather_icons.json
           └── weather_settings.jsonc
   ```

2. **Make the script executable:**

   ```bash
   chmod +x ~/.config/waybar/scripts/weather/get_weather.rb
   ```

## ⚙️ Configuration

1. **Add the module to your Waybar `config.jsonc`:**

   Add `"custom/weather"` to your `modules-left`, `modules-center`, or `modules-right` section. Then, add the following module configuration:

   ```jsonc
   "custom/weather": {
       "format": "{}",
       "tooltip": true,
       "return-type": "json",
       "exec": "~/.config/waybar/scripts/weather/get_weather.rb",
       "on-click": "~/.config/waybar/scripts/weather/get_weather.rb --next", // Cycle views
       "interval": 900 // Every 15 minutes
   },
   ```

2. **Configure the weather script:**

   Edit `~/.config/waybar/scripts/weather/weather_settings.jsonc` to customize the widget.

   ```jsonc
   {
     "latitude": "auto", // e.g., 40.71 or "auto" to detect from IP address
     "longitude": "auto", // e.g., -74.01 or "auto" to detect from IP address
     "refresh_interval": 900, // Seconds between API calls (e.g., 900 = 15 min)
     "unit": "Fahrenheit", // "Fahrenheit" or "Celsius"
     "time_format": "24h", // "24h" or "12h"
     "icon_type": "nerd", // "nerd" or "emoji"
     "icon_position": "left", // "left" or "right"
     "font_size": 14, // Base font size for icons (in px)
     "hours_ahead": 12, // Number of hours to show in hourly tooltip (max 24)
     "forecast_days": 10, // Number of days for forecast (max 16)
     "colors": {
       "primary": "#42A5F5", // Icon default
       "cold": "skyblue", // Temp cold
       "neutral": "#42A5F5", // Temp neutral
       "warm": "khaki", // Temp warm
       "hot": "indianred", // Temp hot
       "pop_low": "#EAD7FF", // Precipitation low
       "pop_med": "#CFA7FF", // Precipitation medium
       "pop_high": "#BC85FF", // Precipitation high
       "pop_vhigh": "#A855F7", // Precipitation very high
       "divider": "#2B3B57", // Divider color
     },
   }
   ```

## 💡 Usage

- **Hover** over the widget to see the detailed weather tooltip.
- **Click** on the widget to cycle between the `default` and `weekview` tooltips.

You can also manually set the view from your terminal:

```bash
# Cycle to the next view
~/.config/waybar/scripts/weather/get_weather.rb --next # --toggle is an alias

# Cycle to the previous view
~/.config/waybar/scripts/weather/get_weather.rb --prev

# Set a specific view
~/.config/waybar/scripts/weather/get_weather.rb --set default
~/.config/waybar/scripts/weather/get_weather.rb --set weekview
```

## 📦 Dependencies

- **Ruby:** The script is written in Ruby and uses standard libraries.
- **Nerd Font:** A Nerd Font is required to display the weather icons correctly. You can download one from [nerdfonts.com](https://www.nerdfonts.com/).

## 🙏 Credits

- **Weather Data:** [Open-Meteo](https://open-meteo.com/)
- **Geolocation:** [ip-api.com](https://ip-api.com/)
