# Generated by the protocol buffer compiler.  DO NOT EDIT!
# source: meshtastic/telemetry.proto

require 'google/protobuf'

Google::Protobuf::DescriptorPool.generated_pool.build do
  add_file("meshtastic/telemetry.proto", :syntax => :proto3) do
    add_message "meshtastic.DeviceMetrics" do
      proto3_optional :battery_level, :uint32, 1
      proto3_optional :voltage, :float, 2
      proto3_optional :channel_utilization, :float, 3
      proto3_optional :air_util_tx, :float, 4
      proto3_optional :uptime_seconds, :uint32, 5
    end
    add_message "meshtastic.EnvironmentMetrics" do
      proto3_optional :temperature, :float, 1
      proto3_optional :relative_humidity, :float, 2
      proto3_optional :barometric_pressure, :float, 3
      proto3_optional :gas_resistance, :float, 4
      proto3_optional :voltage, :float, 5
      proto3_optional :current, :float, 6
      proto3_optional :iaq, :uint32, 7
      proto3_optional :distance, :float, 8
      proto3_optional :lux, :float, 9
      proto3_optional :white_lux, :float, 10
      proto3_optional :ir_lux, :float, 11
      proto3_optional :uv_lux, :float, 12
      proto3_optional :wind_direction, :uint32, 13
      proto3_optional :wind_speed, :float, 14
      proto3_optional :weight, :float, 15
      proto3_optional :wind_gust, :float, 16
      proto3_optional :wind_lull, :float, 17
      proto3_optional :radiation, :float, 18
    end
    add_message "meshtastic.PowerMetrics" do
      proto3_optional :ch1_voltage, :float, 1
      proto3_optional :ch1_current, :float, 2
      proto3_optional :ch2_voltage, :float, 3
      proto3_optional :ch2_current, :float, 4
      proto3_optional :ch3_voltage, :float, 5
      proto3_optional :ch3_current, :float, 6
    end
    add_message "meshtastic.AirQualityMetrics" do
      proto3_optional :pm10_standard, :uint32, 1
      proto3_optional :pm25_standard, :uint32, 2
      proto3_optional :pm100_standard, :uint32, 3
      proto3_optional :pm10_environmental, :uint32, 4
      proto3_optional :pm25_environmental, :uint32, 5
      proto3_optional :pm100_environmental, :uint32, 6
      proto3_optional :particles_03um, :uint32, 7
      proto3_optional :particles_05um, :uint32, 8
      proto3_optional :particles_10um, :uint32, 9
      proto3_optional :particles_25um, :uint32, 10
      proto3_optional :particles_50um, :uint32, 11
      proto3_optional :particles_100um, :uint32, 12
      proto3_optional :co2, :uint32, 13
    end
    add_message "meshtastic.LocalStats" do
      optional :uptime_seconds, :uint32, 1
      optional :channel_utilization, :float, 2
      optional :air_util_tx, :float, 3
      optional :num_packets_tx, :uint32, 4
      optional :num_packets_rx, :uint32, 5
      optional :num_packets_rx_bad, :uint32, 6
      optional :num_online_nodes, :uint32, 7
      optional :num_total_nodes, :uint32, 8
      optional :num_rx_dupe, :uint32, 9
      optional :num_tx_relay, :uint32, 10
      optional :num_tx_relay_canceled, :uint32, 11
    end
    add_message "meshtastic.HealthMetrics" do
      proto3_optional :heart_bpm, :uint32, 1
      proto3_optional :spO2, :uint32, 2
      proto3_optional :temperature, :float, 3
    end
    add_message "meshtastic.Telemetry" do
      optional :time, :fixed32, 1
      oneof :variant do
        optional :device_metrics, :message, 2, "meshtastic.DeviceMetrics"
        optional :environment_metrics, :message, 3, "meshtastic.EnvironmentMetrics"
        optional :air_quality_metrics, :message, 4, "meshtastic.AirQualityMetrics"
        optional :power_metrics, :message, 5, "meshtastic.PowerMetrics"
        optional :local_stats, :message, 6, "meshtastic.LocalStats"
        optional :health_metrics, :message, 7, "meshtastic.HealthMetrics"
      end
    end
    add_message "meshtastic.Nau7802Config" do
      optional :zeroOffset, :int32, 1
      optional :calibrationFactor, :float, 2
    end
    add_enum "meshtastic.TelemetrySensorType" do
      value :SENSOR_UNSET, 0
      value :BME280, 1
      value :BME680, 2
      value :MCP9808, 3
      value :INA260, 4
      value :INA219, 5
      value :BMP280, 6
      value :SHTC3, 7
      value :LPS22, 8
      value :QMC6310, 9
      value :QMI8658, 10
      value :QMC5883L, 11
      value :SHT31, 12
      value :PMSA003I, 13
      value :INA3221, 14
      value :BMP085, 15
      value :RCWL9620, 16
      value :SHT4X, 17
      value :VEML7700, 18
      value :MLX90632, 19
      value :OPT3001, 20
      value :LTR390UV, 21
      value :TSL25911FN, 22
      value :AHT10, 23
      value :DFROBOT_LARK, 24
      value :NAU7802, 25
      value :BMP3XX, 26
      value :ICM20948, 27
      value :MAX17048, 28
      value :CUSTOM_SENSOR, 29
      value :MAX30102, 30
      value :MLX90614, 31
      value :SCD4X, 32
      value :RADSENS, 33
      value :INA226, 34
    end
  end
end

module Meshtastic
  DeviceMetrics = ::Google::Protobuf::DescriptorPool.generated_pool.lookup("meshtastic.DeviceMetrics").msgclass
  EnvironmentMetrics = ::Google::Protobuf::DescriptorPool.generated_pool.lookup("meshtastic.EnvironmentMetrics").msgclass
  PowerMetrics = ::Google::Protobuf::DescriptorPool.generated_pool.lookup("meshtastic.PowerMetrics").msgclass
  AirQualityMetrics = ::Google::Protobuf::DescriptorPool.generated_pool.lookup("meshtastic.AirQualityMetrics").msgclass
  LocalStats = ::Google::Protobuf::DescriptorPool.generated_pool.lookup("meshtastic.LocalStats").msgclass
  HealthMetrics = ::Google::Protobuf::DescriptorPool.generated_pool.lookup("meshtastic.HealthMetrics").msgclass
  Telemetry = ::Google::Protobuf::DescriptorPool.generated_pool.lookup("meshtastic.Telemetry").msgclass
  Nau7802Config = ::Google::Protobuf::DescriptorPool.generated_pool.lookup("meshtastic.Nau7802Config").msgclass
  TelemetrySensorType = ::Google::Protobuf::DescriptorPool.generated_pool.lookup("meshtastic.TelemetrySensorType").enummodule
end
