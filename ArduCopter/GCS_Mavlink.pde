// -*- tab-width: 4; Mode: C++; c-basic-offset: 4; indent-tabs-mode: nil -*-

// default sensors are present and healthy: gyro, accelerometer, barometer, rate_control, attitude_stabilization, yaw_position, altitude control, x/y position control, motor_control
#define MAVLINK_SENSOR_PRESENT_DEFAULT (MAV_SYS_STATUS_SENSOR_3D_GYRO | MAV_SYS_STATUS_SENSOR_3D_ACCEL | MAV_SYS_STATUS_SENSOR_ABSOLUTE_PRESSURE | MAV_SYS_STATUS_SENSOR_ANGULAR_RATE_CONTROL | MAV_SYS_STATUS_SENSOR_ATTITUDE_STABILIZATION | MAV_SYS_STATUS_SENSOR_YAW_POSITION | MAV_SYS_STATUS_SENSOR_Z_ALTITUDE_CONTROL | MAV_SYS_STATUS_SENSOR_XY_POSITION_CONTROL | MAV_SYS_STATUS_SENSOR_MOTOR_OUTPUTS)

// forward declarations to make compiler happy
static bool do_guided(const AP_Mission::Mission_Command& cmd);

// use this to prevent recursion during sensor init
static bool in_mavlink_delay;

// true when we have received at least 1 MAVLink packet
static bool mavlink_active;

// true if we are out of time in our event timeslice
static bool	gcs_out_of_time;


// check if a message will fit in the payload space available
#define CHECK_PAYLOAD_SIZE(id) if (payload_space < MAVLINK_MSG_ID_ ## id ## _LEN) return false

// prototype this for use inside the GCS class
static void gcs_send_text_fmt(const prog_char_t *fmt, ...);

static void gcs_send_heartbeat(void)
{
    gcs_send_message(MSG_HEARTBEAT);
}

static void gcs_send_deferred(void)
{
    gcs_send_message(MSG_RETRY_DEFERRED);
}

/*
 *  !!NOTE!!
 *
 *  the use of NOINLINE separate functions for each message type avoids
 *  a compiler bug in gcc that would cause it to use far more stack
 *  space than is needed. Without the NOINLINE we use the sum of the
 *  stack needed for each message type. Please be careful to follow the
 *  pattern below when adding any new messages
 */

static NOINLINE void send_heartbeat(mavlink_channel_t chan)
{
    uint8_t base_mode = MAV_MODE_FLAG_CUSTOM_MODE_ENABLED;
    uint8_t system_status = ap.land_complete ? MAV_STATE_STANDBY : MAV_STATE_ACTIVE;
    uint32_t custom_mode = control_mode;

    // set system as critical if any failsafe have triggered
    if (failsafe.radio || failsafe.battery || failsafe.gps || failsafe.gcs)  {
        system_status = MAV_STATE_CRITICAL;
    }
    
    // work out the base_mode. This value is not very useful
    // for APM, but we calculate it as best we can so a generic
    // MAVLink enabled ground station can work out something about
    // what the MAV is up to. The actual bit values are highly
    // ambiguous for most of the APM flight modes. In practice, you
    // only get useful information from the custom_mode, which maps to
    // the APM flight mode and has a well defined meaning in the
    // ArduPlane documentation
    base_mode = MAV_MODE_FLAG_STABILIZE_ENABLED;
    switch (control_mode) {
    case AUTO:
    case RTL:
    case LOITER:
    case GUIDED:
    case CIRCLE:
        base_mode |= MAV_MODE_FLAG_GUIDED_ENABLED;
        // note that MAV_MODE_FLAG_AUTO_ENABLED does not match what
        // APM does in any mode, as that is defined as "system finds its own goal
        // positions", which APM does not currently do
        break;
    }

    // all modes except INITIALISING have some form of manual
    // override if stick mixing is enabled
    base_mode |= MAV_MODE_FLAG_MANUAL_INPUT_ENABLED;

#if HIL_MODE != HIL_MODE_DISABLED
    base_mode |= MAV_MODE_FLAG_HIL_ENABLED;
#endif

    // we are armed if we are not initialising
    if (motors.armed()) {
        base_mode |= MAV_MODE_FLAG_SAFETY_ARMED;
    }

    // indicate we have set a custom mode
    base_mode |= MAV_MODE_FLAG_CUSTOM_MODE_ENABLED;

    mavlink_msg_heartbeat_send(
        chan,
#if (FRAME_CONFIG == QUAD_FRAME)
        MAV_TYPE_QUADROTOR,
#elif (FRAME_CONFIG == TRI_FRAME)
        MAV_TYPE_TRICOPTER,
#elif (FRAME_CONFIG == HEXA_FRAME || FRAME_CONFIG == Y6_FRAME)
        MAV_TYPE_HEXAROTOR,
#elif (FRAME_CONFIG == OCTA_FRAME || FRAME_CONFIG == OCTA_QUAD_FRAME)
        MAV_TYPE_OCTOROTOR,
#elif (FRAME_CONFIG == HELI_FRAME)
        MAV_TYPE_HELICOPTER,
#elif (FRAME_CONFIG == SINGLE_FRAME)  //because mavlink did not define a singlecopter, we use a rocket
        MAV_TYPE_ROCKET,
#elif (FRAME_CONFIG == COAX_FRAME)  //because mavlink did not define a singlecopter, we use a rocket
        MAV_TYPE_ROCKET,
#else
  #error Unrecognised frame type
#endif
        MAV_AUTOPILOT_ARDUPILOTMEGA,
        base_mode,
        custom_mode,
        system_status);
}

static NOINLINE void send_attitude(mavlink_channel_t chan)
{
    const Vector3f &gyro = ins.get_gyro();
    mavlink_msg_attitude_send(
        chan,
        millis(),
        ahrs.roll,
        ahrs.pitch,
        ahrs.yaw,
        gyro.x,
        gyro.y,
        gyro.z);
}

#if AC_FENCE == ENABLED
static NOINLINE void send_limits_status(mavlink_channel_t chan)
{
    fence_send_mavlink_status(chan);
}
#endif


static NOINLINE void send_extended_status1(mavlink_channel_t chan, uint16_t packet_drops)
{
    uint32_t control_sensors_present;
    uint32_t control_sensors_enabled;
    uint32_t control_sensors_health;

    // default sensors present
    control_sensors_present = MAVLINK_SENSOR_PRESENT_DEFAULT;

    // first what sensors/controllers we have
    if (g.compass_enabled) {
        control_sensors_present |= MAV_SYS_STATUS_SENSOR_3D_MAG; // compass present
    }
    if (g_gps != NULL && g_gps->status() > GPS::NO_GPS) {
        control_sensors_present |= MAV_SYS_STATUS_SENSOR_GPS;
    }
#if OPTFLOW == ENABLED
    if (g.optflow_enabled) {
        control_sensors_present |= MAV_SYS_STATUS_SENSOR_OPTICAL_FLOW;
    }
#endif
    if (ap.rc_receiver_present) {
        control_sensors_present |= MAV_SYS_STATUS_SENSOR_RC_RECEIVER;
    }

    // all present sensors enabled by default except altitude and position control which we will set individually
    control_sensors_enabled = control_sensors_present & (~MAV_SYS_STATUS_SENSOR_Z_ALTITUDE_CONTROL & ~MAV_SYS_STATUS_SENSOR_XY_POSITION_CONTROL);

    switch (control_mode) {
    case ALT_HOLD:
    case AUTO:
    case GUIDED:
    case LOITER:
    case RTL:
    case CIRCLE:
    case LAND:
    case OF_LOITER:
        control_sensors_enabled |= MAV_SYS_STATUS_SENSOR_Z_ALTITUDE_CONTROL;
        control_sensors_enabled |= MAV_SYS_STATUS_SENSOR_XY_POSITION_CONTROL;
        break;
    case SPORT:
        control_sensors_enabled |= MAV_SYS_STATUS_SENSOR_Z_ALTITUDE_CONTROL;
        break;
    }

    // default to all healthy except compass, gps and receiver which we set individually
    control_sensors_health = control_sensors_present & (~MAV_SYS_STATUS_SENSOR_3D_MAG & ~MAV_SYS_STATUS_SENSOR_GPS & ~MAV_SYS_STATUS_SENSOR_RC_RECEIVER);
    if (g.compass_enabled && compass.healthy() && ahrs.use_compass()) {
        control_sensors_health |= MAV_SYS_STATUS_SENSOR_3D_MAG;
    }
    if (g_gps != NULL && g_gps->status() > GPS::NO_GPS && (!gps_glitch.glitching()||ap.usb_connected)) {
        control_sensors_health |= MAV_SYS_STATUS_SENSOR_GPS;
    }
    if (ap.rc_receiver_present && !failsafe.radio) {
        control_sensors_health |= MAV_SYS_STATUS_SENSOR_RC_RECEIVER;
    }
    if (!ins.healthy()) {
        control_sensors_health &= ~(MAV_SYS_STATUS_SENSOR_3D_GYRO | MAV_SYS_STATUS_SENSOR_3D_ACCEL);
    }

    int16_t battery_current = -1;
    int8_t battery_remaining = -1;

    if (battery.monitoring() == AP_BATT_MONITOR_VOLTAGE_AND_CURRENT) {
        battery_remaining = battery.capacity_remaining_pct();
        battery_current = battery.current_amps() * 100;
    }

    mavlink_msg_sys_status_send(
        chan,
        control_sensors_present,
        control_sensors_enabled,
        control_sensors_health,
        (uint16_t)(scheduler.load_average(10000) * 1000),
        battery.voltage() * 1000, // mV
        battery_current,        // in 10mA units
        battery_remaining,      // in %
        0, // comm drops %,
        0, // comm drops in pkts,
        0, 0, 0, 0);

}

static void NOINLINE send_location(mavlink_channel_t chan)
{
    uint32_t fix_time;
    // if we have a GPS fix, take the time as the last fix time. That
    // allows us to correctly calculate velocities and extrapolate
    // positions.
    // If we don't have a GPS fix then we are dead reckoning, and will
    // use the current boot time as the fix time.    
    if (g_gps->status() >= GPS::GPS_OK_FIX_2D) {
        fix_time = g_gps->last_fix_time;
    } else {
        fix_time = millis();
    }
    mavlink_msg_global_position_int_send(
        chan,
        fix_time,
        current_loc.lat,                // in 1E7 degrees
        current_loc.lng,                // in 1E7 degrees
        g_gps->altitude_cm * 10,             // millimeters above sea level
        (current_loc.alt - home.alt) * 10,           // millimeters above ground
        g_gps->velocity_north() * 100,  // X speed cm/s (+ve North)
        g_gps->velocity_east()  * 100,  // Y speed cm/s (+ve East)
        g_gps->velocity_down()  * -100, // Z speed cm/s (+ve up)
        ahrs.yaw_sensor);               // compass heading in 1/100 degree
}

static void NOINLINE send_nav_controller_output(mavlink_channel_t chan)
{
    Vector3f targets;
    get_angle_targets_for_reporting(targets);
    mavlink_msg_nav_controller_output_send(
        chan,
        targets.x / 1.0e2f,
        targets.y / 1.0e2f,
        targets.z / 1.0e2f,
        wp_bearing / 1.0e2f,
        wp_distance / 1.0e2f,
        pos_control.get_alt_error() / 1.0e2f,
        0,
        0);
}

static void NOINLINE send_ahrs(mavlink_channel_t chan)
{
    const Vector3f &omega_I = ahrs.get_gyro_drift();
    mavlink_msg_ahrs_send(
        chan,
        omega_I.x,
        omega_I.y,
        omega_I.z,
        1,
        0,
        ahrs.get_error_rp(),
        ahrs.get_error_yaw());
}

// report simulator state
static void NOINLINE send_simstate(mavlink_channel_t chan)
{
#if CONFIG_HAL_BOARD == HAL_BOARD_AVR_SITL
    sitl.simstate_send(chan);
#endif
}

static void NOINLINE send_hwstatus(mavlink_channel_t chan)
{
    mavlink_msg_hwstatus_send(
        chan,
        hal.analogin->board_voltage()*1000,
        hal.i2c->lockup_count());
}

static void NOINLINE send_gps_raw(mavlink_channel_t chan)
{
    mavlink_msg_gps_raw_int_send(
        chan,
        g_gps->last_fix_time*(uint64_t)1000,
        g_gps->status(),
        g_gps->latitude,      // in 1E7 degrees
        g_gps->longitude,     // in 1E7 degrees
        g_gps->altitude_cm * 10, // in mm
        g_gps->hdop,
        65535,
        g_gps->ground_speed_cm,  // cm/s
        g_gps->ground_course_cd, // 1/100 degrees,
        g_gps->num_sats);

#if GPS2_ENABLE
    if (g_gps2 != NULL && g_gps2->status() != GPS::NO_GPS) {
        int16_t payload_space = comm_get_txspace(chan) - MAVLINK_NUM_NON_PAYLOAD_BYTES;
        if (payload_space >= MAVLINK_MSG_ID_GPS2_RAW_LEN) {
            mavlink_msg_gps2_raw_send(
                chan,
                g_gps2->last_fix_time*(uint64_t)1000,
                g_gps2->status(),
                g_gps2->latitude,      // in 1E7 degrees
                g_gps2->longitude,     // in 1E7 degrees
                g_gps2->altitude_cm * 10, // in mm
                g_gps2->hdop,
                65535,
                g_gps2->ground_speed_cm,  // cm/s
                g_gps2->ground_course_cd, // 1/100 degrees,
                g_gps2->num_sats,
                0, 
                0);
        }
    }
#endif
}

static void NOINLINE send_system_time(mavlink_channel_t chan)
{
    mavlink_msg_system_time_send(
        chan,
        g_gps->time_epoch_usec(),
        hal.scheduler->millis());
}

#if HIL_MODE != HIL_MODE_DISABLED
static void NOINLINE send_servo_out(mavlink_channel_t chan)
{
    // normalized values scaled to -10000 to 10000
    // This is used for HIL.  Do not change without discussing with HIL maintainers

#if FRAME_CONFIG == HELI_FRAME

    mavlink_msg_rc_channels_scaled_send(
        chan,
        millis(),
        0, // port 0
        g.rc_1.servo_out,
        g.rc_2.servo_out,
        g.rc_3.radio_out,
        g.rc_4.servo_out,
        0,
        0,
        0,
        0,
        receiver_rssi);
#else
 #if X_PLANE == ENABLED
    /* update by JLN for X-Plane HIL */
    if(motors.armed() && ap.auto_armed) {
        mavlink_msg_rc_channels_scaled_send(
            chan,
            millis(),
            0,         // port 0
            g.rc_1.servo_out,
            g.rc_2.servo_out,
            10000 * g.rc_3.norm_output(),
            g.rc_4.servo_out,
            10000 * g.rc_1.norm_output(),
            10000 * g.rc_2.norm_output(),
            10000 * g.rc_3.norm_output(),
            10000 * g.rc_4.norm_output(),
            receiver_rssi);
    }else{
        mavlink_msg_rc_channels_scaled_send(
            chan,
            millis(),
            0,         // port 0
            0,
            0,
            -10000,
            0,
            10000 * g.rc_1.norm_output(),
            10000 * g.rc_2.norm_output(),
            10000 * g.rc_3.norm_output(),
            10000 * g.rc_4.norm_output(),
            receiver_rssi);
    }

 #else
    mavlink_msg_rc_channels_scaled_send(
        chan,
        millis(),
        0,         // port 0
        g.rc_1.servo_out,
        g.rc_2.servo_out,
        g.rc_3.radio_out,
        g.rc_4.servo_out,
        10000 * g.rc_1.norm_output(),
        10000 * g.rc_2.norm_output(),
        10000 * g.rc_3.norm_output(),
        10000 * g.rc_4.norm_output(),
        receiver_rssi);
 #endif
#endif
}
#endif // HIL_MODE

static void NOINLINE send_radio_in(mavlink_channel_t chan)
{
    mavlink_msg_rc_channels_raw_send(
        chan,
        millis(),
        0, // port
        g.rc_1.radio_in,
        g.rc_2.radio_in,
        g.rc_3.radio_in,
        g.rc_4.radio_in,
        g.rc_5.radio_in,
        g.rc_6.radio_in,
        g.rc_7.radio_in,
        g.rc_8.radio_in,
        receiver_rssi);
}

static void NOINLINE send_radio_out(mavlink_channel_t chan)
{
    uint8_t i;
    uint16_t rcout[8];
    hal.rcout->read(rcout,8);
    // clear out unreasonable values
    for (i=0; i<8; i++) {
        if (rcout[i] > 10000) {
            rcout[i] = 0;
        }
    }
    mavlink_msg_servo_output_raw_send(
        chan,
        micros(),
        0, // port
        rcout[0],
        rcout[1],
        rcout[2],
        rcout[3],
        rcout[4],
        rcout[5],
        rcout[6],
        rcout[7]);
}

static void NOINLINE send_vfr_hud(mavlink_channel_t chan)
{
    mavlink_msg_vfr_hud_send(
        chan,
        (float)g_gps->ground_speed_cm / 100.0f,
        (float)g_gps->ground_speed_cm / 100.0f,
        (ahrs.yaw_sensor / 100) % 360,
        g.rc_3.servo_out/10,
        current_loc.alt / 100.0f,
        climb_rate / 100.0f);
}

static void NOINLINE send_raw_imu1(mavlink_channel_t chan)
{
    const Vector3f &accel = ins.get_accel();
    const Vector3f &gyro = ins.get_gyro();
    const Vector3f &mag = compass.get_field();
    mavlink_msg_raw_imu_send(
        chan,
        micros(),
        accel.x * 1000.0f / GRAVITY_MSS,
        accel.y * 1000.0f / GRAVITY_MSS,
        accel.z * 1000.0f / GRAVITY_MSS,
        gyro.x * 1000.0f,
        gyro.y * 1000.0f,
        gyro.z * 1000.0f,
        mag.x,
        mag.y,
        mag.z);
    if (ins.get_gyro_count() <= 1 &&
        ins.get_accel_count() <= 1 &&
        compass.get_count() <= 1) {
        return;
    }
    const Vector3f &accel2 = ins.get_accel(1);
    const Vector3f &gyro2 = ins.get_gyro(1);
    const Vector3f &mag2 = compass.get_field(1);
    mavlink_msg_scaled_imu2_send(
        chan,
        millis(),
        accel2.x * 1000.0f / GRAVITY_MSS,
        accel2.y * 1000.0f / GRAVITY_MSS,
        accel2.z * 1000.0f / GRAVITY_MSS,
        gyro2.x * 1000.0f,
        gyro2.y * 1000.0f,
        gyro2.z * 1000.0f,
        mag2.x,
        mag2.y,
        mag2.z);        
}

static void NOINLINE send_raw_imu2(mavlink_channel_t chan)
{
    mavlink_msg_scaled_pressure_send(
        chan,
        millis(),
        barometer.get_pressure()*0.01f, // hectopascal
        (barometer.get_pressure() - barometer.get_ground_pressure())*0.01f, // hectopascal
        (int16_t)(barometer.get_temperature()*100)); // 0.01 degrees C
}

static void NOINLINE send_raw_imu3(mavlink_channel_t chan)
{
    const Vector3f &mag_offsets = compass.get_offsets();
    const Vector3f &accel_offsets = ins.get_accel_offsets();
    const Vector3f &gyro_offsets = ins.get_gyro_offsets();

    mavlink_msg_sensor_offsets_send(chan,
                                    mag_offsets.x,
                                    mag_offsets.y,
                                    mag_offsets.z,
                                    compass.get_declination(),
                                    barometer.get_pressure(),
                                    barometer.get_temperature()*100,
                                    gyro_offsets.x,
                                    gyro_offsets.y,
                                    gyro_offsets.z,
                                    accel_offsets.x,
                                    accel_offsets.y,
                                    accel_offsets.z);
}

static void NOINLINE send_current_waypoint(mavlink_channel_t chan)
{
    uint16_t current_cmd_index;
    if (mission.state() == AP_Mission::MISSION_RUNNING) {
        current_cmd_index = mission.get_current_nav_cmd().index;
    }else{
        current_cmd_index = AP_MISSION_CMD_INDEX_NONE;
    }
    mavlink_msg_mission_current_send(chan, current_cmd_index);
}

static void NOINLINE send_statustext(mavlink_channel_t chan)
{
    mavlink_statustext_t *s = &gcs[chan-MAVLINK_COMM_0].pending_status;
    mavlink_msg_statustext_send(
        chan,
        s->severity,
        s->text);
}

// are we still delaying telemetry to try to avoid Xbee bricking?
static bool telemetry_delayed(mavlink_channel_t chan)
{
    uint32_t tnow = millis() >> 10;
    if (tnow > (uint32_t)g.telem_delay) {
        return false;
    }
    if (chan == MAVLINK_COMM_0 && hal.gpio->usb_connected()) {
        // this is USB telemetry, so won't be an Xbee
        return false;
    }
    // we're either on the 2nd UART, or no USB cable is connected
    // we need to delay telemetry by the TELEM_DELAY time
    return true;
}


// try to send a message, return false if it won't fit in the serial tx buffer
static bool mavlink_try_send_message(mavlink_channel_t chan, enum ap_message id, uint16_t packet_drops)
{
    int16_t payload_space = comm_get_txspace(chan) - MAVLINK_NUM_NON_PAYLOAD_BYTES;

    if (telemetry_delayed(chan)) {
        return false;
    }

#if HIL_MODE != HIL_MODE_SENSORS
    // if we don't have at least 250 micros remaining before the main loop
    // wants to fire then don't send a mavlink message. We want to
    // prioritise the main flight control loop over communications
    if (scheduler.time_available_usec() < 250 && motors.armed()) {
        gcs_out_of_time = true;
        return false;
    }
#endif

    switch(id) {
    case MSG_HEARTBEAT:
        CHECK_PAYLOAD_SIZE(HEARTBEAT);
        gcs[chan-MAVLINK_COMM_0].last_heartbeat_time = hal.scheduler->millis();
        send_heartbeat(chan);
        break;

    case MSG_EXTENDED_STATUS1:
        CHECK_PAYLOAD_SIZE(SYS_STATUS);
        send_extended_status1(chan, packet_drops);
        CHECK_PAYLOAD_SIZE(POWER_STATUS);
        gcs[chan-MAVLINK_COMM_0].send_power_status();
        break;

    case MSG_EXTENDED_STATUS2:
        CHECK_PAYLOAD_SIZE(MEMINFO);
        gcs[chan-MAVLINK_COMM_0].send_meminfo();
        break;

    case MSG_ATTITUDE:
        CHECK_PAYLOAD_SIZE(ATTITUDE);
        send_attitude(chan);
        break;

    case MSG_LOCATION:
        CHECK_PAYLOAD_SIZE(GLOBAL_POSITION_INT);
        send_location(chan);
        break;

    case MSG_NAV_CONTROLLER_OUTPUT:
        CHECK_PAYLOAD_SIZE(NAV_CONTROLLER_OUTPUT);
        send_nav_controller_output(chan);
        break;

    case MSG_GPS_RAW:
        CHECK_PAYLOAD_SIZE(GPS_RAW_INT);
        send_gps_raw(chan);
        break;

    case MSG_SYSTEM_TIME:
        CHECK_PAYLOAD_SIZE(SYSTEM_TIME);
        send_system_time(chan);
        break;

    case MSG_SERVO_OUT:
#if HIL_MODE != HIL_MODE_DISABLED
        CHECK_PAYLOAD_SIZE(RC_CHANNELS_SCALED);
        send_servo_out(chan);
#endif
        break;

    case MSG_RADIO_IN:
        CHECK_PAYLOAD_SIZE(RC_CHANNELS_RAW);
        send_radio_in(chan);
        break;

    case MSG_RADIO_OUT:
        CHECK_PAYLOAD_SIZE(SERVO_OUTPUT_RAW);
        send_radio_out(chan);
        break;

    case MSG_VFR_HUD:
        CHECK_PAYLOAD_SIZE(VFR_HUD);
        send_vfr_hud(chan);
        break;

    case MSG_RAW_IMU1:
        CHECK_PAYLOAD_SIZE(RAW_IMU);
        send_raw_imu1(chan);
        break;

    case MSG_RAW_IMU2:
        CHECK_PAYLOAD_SIZE(SCALED_PRESSURE);
        send_raw_imu2(chan);
        break;

    case MSG_RAW_IMU3:
        CHECK_PAYLOAD_SIZE(SENSOR_OFFSETS);
        send_raw_imu3(chan);
        break;

    case MSG_CURRENT_WAYPOINT:
        CHECK_PAYLOAD_SIZE(MISSION_CURRENT);
        send_current_waypoint(chan);
        break;

    case MSG_NEXT_PARAM:
        CHECK_PAYLOAD_SIZE(PARAM_VALUE);
        gcs[chan-MAVLINK_COMM_0].queued_param_send();
        break;

    case MSG_NEXT_WAYPOINT:
        CHECK_PAYLOAD_SIZE(MISSION_REQUEST);
        gcs[chan-MAVLINK_COMM_0].queued_waypoint_send();
        break;

    case MSG_STATUSTEXT:
        CHECK_PAYLOAD_SIZE(STATUSTEXT);
        send_statustext(chan);
        break;

#if AC_FENCE == ENABLED
    case MSG_LIMITS_STATUS:
        CHECK_PAYLOAD_SIZE(LIMITS_STATUS);
        send_limits_status(chan);
        break;
#endif

    case MSG_AHRS:
        CHECK_PAYLOAD_SIZE(AHRS);
        send_ahrs(chan);
        break;

    case MSG_SIMSTATE:
#if CONFIG_HAL_BOARD == HAL_BOARD_AVR_SITL
        CHECK_PAYLOAD_SIZE(SIMSTATE);
        send_simstate(chan);
#endif
#if AP_AHRS_NAVEKF_AVAILABLE
        CHECK_PAYLOAD_SIZE(AHRS2);
        gcs[chan-MAVLINK_COMM_0].send_ahrs2(ahrs);
#endif
        break;

    case MSG_HWSTATUS:
        CHECK_PAYLOAD_SIZE(HWSTATUS);
        send_hwstatus(chan);
        break;

    case MSG_FENCE_STATUS:
    case MSG_WIND:
    case MSG_RANGEFINDER:
        // unused
        break;

    case MSG_RETRY_DEFERRED:
        break; // just here to prevent a warning
    }

    return true;
}


#define MAX_DEFERRED_MESSAGES MSG_RETRY_DEFERRED
static struct mavlink_queue {
    enum ap_message deferred_messages[MAX_DEFERRED_MESSAGES];
    uint8_t next_deferred_message;
    uint8_t num_deferred_messages;
} mavlink_queue[MAVLINK_COMM_NUM_BUFFERS];

// send a message using mavlink
static void mavlink_send_message(mavlink_channel_t chan, enum ap_message id, uint16_t packet_drops)
{
    uint8_t i, nextid;
    struct mavlink_queue *q = &mavlink_queue[(uint8_t)chan];

    // see if we can send the deferred messages, if any
    while (q->num_deferred_messages != 0) {
        if (!mavlink_try_send_message(chan,
                                      q->deferred_messages[q->next_deferred_message],
                                      packet_drops)) {
            break;
        }
        q->next_deferred_message++;
        if (q->next_deferred_message == MAX_DEFERRED_MESSAGES) {
            q->next_deferred_message = 0;
        }
        q->num_deferred_messages--;
    }

    if (id == MSG_RETRY_DEFERRED) {
        return;
    }

    // this message id might already be deferred
    for (i=0, nextid = q->next_deferred_message; i < q->num_deferred_messages; i++) {
        if (q->deferred_messages[nextid] == id) {
            // its already deferred, discard
            return;
        }
        nextid++;
        if (nextid == MAX_DEFERRED_MESSAGES) {
            nextid = 0;
        }
    }

    if (q->num_deferred_messages != 0 ||
        !mavlink_try_send_message(chan, id, packet_drops)) {
        // can't send it now, so defer it
        if (q->num_deferred_messages == MAX_DEFERRED_MESSAGES) {
            // the defer buffer is full, discard
            return;
        }
        nextid = q->next_deferred_message + q->num_deferred_messages;
        if (nextid >= MAX_DEFERRED_MESSAGES) {
            nextid -= MAX_DEFERRED_MESSAGES;
        }
        q->deferred_messages[nextid] = id;
        q->num_deferred_messages++;
    }
}

void mavlink_send_text(mavlink_channel_t chan, gcs_severity severity, const char *str)
{
    if (telemetry_delayed(chan)) {
        return;
    }

    if (severity == SEVERITY_LOW) {
        // send via the deferred queuing system
        mavlink_statustext_t *s = &gcs[chan-MAVLINK_COMM_0].pending_status;
        s->severity = (uint8_t)severity;
        strncpy((char *)s->text, str, sizeof(s->text));
        mavlink_send_message(chan, MSG_STATUSTEXT, 0);
    } else {
        // send immediately
        mavlink_msg_statustext_send(chan, severity, str);
    }
}

const AP_Param::GroupInfo GCS_MAVLINK::var_info[] PROGMEM = {
    // @Param: RAW_SENS
    // @DisplayName: Raw sensor stream rate
    // @Description: Raw sensor stream rate to ground station
    // @Units: Hz
    // @Range: 0 10
    // @Increment: 1
    // @User: Advanced
    AP_GROUPINFO("RAW_SENS", 0, GCS_MAVLINK, streamRates[0],  0),

    // @Param: EXT_STAT
    // @DisplayName: Extended status stream rate to ground station
    // @Description: Extended status stream rate to ground station
    // @Units: Hz
    // @Range: 0 10
    // @Increment: 1
    // @User: Advanced
    AP_GROUPINFO("EXT_STAT", 1, GCS_MAVLINK, streamRates[1],  0),

    // @Param: RC_CHAN
    // @DisplayName: RC Channel stream rate to ground station
    // @Description: RC Channel stream rate to ground station
    // @Units: Hz
    // @Range: 0 10
    // @Increment: 1
    // @User: Advanced
    AP_GROUPINFO("RC_CHAN",  2, GCS_MAVLINK, streamRates[2],  0),

    // @Param: RAW_CTRL
    // @DisplayName: Raw Control stream rate to ground station
    // @Description: Raw Control stream rate to ground station
    // @Units: Hz
    // @Range: 0 10
    // @Increment: 1
    // @User: Advanced
    AP_GROUPINFO("RAW_CTRL", 3, GCS_MAVLINK, streamRates[3],  0),

    // @Param: POSITION
    // @DisplayName: Position stream rate to ground station
    // @Description: Position stream rate to ground station
    // @Units: Hz
    // @Range: 0 10
    // @Increment: 1
    // @User: Advanced
    AP_GROUPINFO("POSITION", 4, GCS_MAVLINK, streamRates[4],  0),

    // @Param: EXTRA1
    // @DisplayName: Extra data type 1 stream rate to ground station
    // @Description: Extra data type 1 stream rate to ground station
    // @Units: Hz
    // @Range: 0 10
    // @Increment: 1
    // @User: Advanced
    AP_GROUPINFO("EXTRA1",   5, GCS_MAVLINK, streamRates[5],  0),

    // @Param: EXTRA2
    // @DisplayName: Extra data type 2 stream rate to ground station
    // @Description: Extra data type 2 stream rate to ground station
    // @Units: Hz
    // @Range: 0 10
    // @Increment: 1
    // @User: Advanced
    AP_GROUPINFO("EXTRA2",   6, GCS_MAVLINK, streamRates[6],  0),

    // @Param: EXTRA3
    // @DisplayName: Extra data type 3 stream rate to ground station
    // @Description: Extra data type 3 stream rate to ground station
    // @Units: Hz
    // @Range: 0 10
    // @Increment: 1
    // @User: Advanced
    AP_GROUPINFO("EXTRA3",   7, GCS_MAVLINK, streamRates[7],  0),

    // @Param: PARAMS
    // @DisplayName: Parameter stream rate to ground station
    // @Description: Parameter stream rate to ground station
    // @Units: Hz
    // @Range: 0 10
    // @Increment: 1
    // @User: Advanced
    AP_GROUPINFO("PARAMS",   8, GCS_MAVLINK, streamRates[8],  0),
    AP_GROUPEND
};

void
GCS_MAVLINK::update(void)
{
    // receive new packets
    mavlink_message_t msg;
    mavlink_status_t status;
    status.packet_rx_drop_count = 0;

    // process received bytes
    uint16_t nbytes = comm_get_available(chan);
    for (uint16_t i=0; i<nbytes; i++)
    {
        uint8_t c = comm_receive_ch(chan);

#if CLI_ENABLED == ENABLED
        /* allow CLI to be started by hitting enter 3 times, if no
         *  heartbeat packets have been received */
        if (mavlink_active == 0 && (millis() - _cli_timeout) < 20000 && 
            !motors.armed() && comm_is_idle(chan)) {
            if (c == '\n' || c == '\r') {
                crlf_count++;
            } else {
                crlf_count = 0;
            }
            if (crlf_count == 3) {
                run_cli(_port);
            }
        }
#endif

        // Try to get a new message
        if (mavlink_parse_char(chan, c, &msg, &status)) {
            // we exclude radio packets to make it possible to use the
            // CLI over the radio
            if (msg.msgid != MAVLINK_MSG_ID_RADIO && msg.msgid != MAVLINK_MSG_ID_RADIO_STATUS) {
                mavlink_active = true;
            }
            handleMessage(&msg);
        }
    }

    // Update packet drops counter
    packet_drops += status.packet_rx_drop_count;

    // handle receiving commands from GCS
    if (waypoint_receiving) {
        uint32_t tnow = millis();

        // request another command from the GCS if at least 500ms has passed
        if (waypoint_request_i <= waypoint_request_last &&
            tnow > waypoint_timelast_request + 500 + (stream_slowdown*20)) {
            waypoint_timelast_request = tnow;
            send_message(MSG_NEXT_WAYPOINT);
        }

        // stop waypoint receiving if timeout
        if ((tnow - waypoint_timelast_receive) > waypoint_receive_timeout) {
            waypoint_receiving = false;
        }
    }
}

// see if we should send a stream now. Called at 50Hz
bool GCS_MAVLINK::stream_trigger(enum streams stream_num)
{
    if (stream_num >= NUM_STREAMS) {
        return false;
    }
    float rate = (uint8_t)streamRates[stream_num].get();

    // send at a much lower rate while handling waypoints and
    // parameter sends
    if ((stream_num != STREAM_PARAMS) && 
        (waypoint_receiving || _queued_parameter != NULL)) {
        rate *= 0.25;
    }

    if (rate <= 0) {
        return false;
    }

    if (stream_ticks[stream_num] == 0) {
        // we're triggering now, setup the next trigger point
        if (rate > 50) {
            rate = 50;
        }
        stream_ticks[stream_num] = (50 / rate) + stream_slowdown;
        return true;
    }

    // count down at 50Hz
    stream_ticks[stream_num]--;
    return false;
}

void
GCS_MAVLINK::data_stream_send(void)
{
    if (waypoint_receiving) {
        // don't interfere with mission transfer
        return;
    }

    if (!in_mavlink_delay && !motors.armed()) {
        handle_log_send(DataFlash);
    }

    gcs_out_of_time = false;

    if (_queued_parameter != NULL) {
        if (streamRates[STREAM_PARAMS].get() <= 0) {
            streamRates[STREAM_PARAMS].set(10);
        }
        if (stream_trigger(STREAM_PARAMS)) {
            send_message(MSG_NEXT_PARAM);
        }
        // don't send anything else at the same time as parameters
        return;
    }

    if (gcs_out_of_time) return;

    if (in_mavlink_delay) {
        // don't send any other stream types while in the delay callback
        return;
    }

    if (stream_trigger(STREAM_RAW_SENSORS)) {
        send_message(MSG_RAW_IMU1);
        send_message(MSG_RAW_IMU2);
        send_message(MSG_RAW_IMU3);
    }

    if (gcs_out_of_time) return;

    if (stream_trigger(STREAM_EXTENDED_STATUS)) {
        send_message(MSG_EXTENDED_STATUS1);
        send_message(MSG_EXTENDED_STATUS2);
        send_message(MSG_CURRENT_WAYPOINT);
        send_message(MSG_GPS_RAW);
        send_message(MSG_NAV_CONTROLLER_OUTPUT);
        send_message(MSG_LIMITS_STATUS);
    }

    if (gcs_out_of_time) return;

    if (stream_trigger(STREAM_POSITION)) {
        send_message(MSG_LOCATION);
    }

    if (gcs_out_of_time) return;

    if (stream_trigger(STREAM_RAW_CONTROLLER)) {
        send_message(MSG_SERVO_OUT);
    }

    if (gcs_out_of_time) return;

    if (stream_trigger(STREAM_RC_CHANNELS)) {
        send_message(MSG_RADIO_OUT);
        send_message(MSG_RADIO_IN);
    }

    if (gcs_out_of_time) return;

    if (stream_trigger(STREAM_EXTRA1)) {
        send_message(MSG_ATTITUDE);
        send_message(MSG_SIMSTATE);
    }

    if (gcs_out_of_time) return;

    if (stream_trigger(STREAM_EXTRA2)) {
        send_message(MSG_VFR_HUD);
    }

    if (gcs_out_of_time) return;

    if (stream_trigger(STREAM_EXTRA3)) {
        send_message(MSG_AHRS);
        send_message(MSG_HWSTATUS);
        send_message(MSG_SYSTEM_TIME);
    }
}



void
GCS_MAVLINK::send_message(enum ap_message id)
{
    mavlink_send_message(chan,id, packet_drops);
}

void
GCS_MAVLINK::send_text_P(gcs_severity severity, const prog_char_t *str)
{
    mavlink_statustext_t m;
    uint8_t i;
    for (i=0; i<sizeof(m.text); i++) {
        m.text[i] = pgm_read_byte((const prog_char *)(str++));
        if (m.text[i] == '\0') {
            break;
        }
    }
    if (i < sizeof(m.text)) m.text[i] = 0;
    mavlink_send_text(chan, severity, (const char *)m.text);
}

void GCS_MAVLINK::handleMessage(mavlink_message_t* msg)
{
    uint8_t result = MAV_RESULT_FAILED;         // assume failure.  Each messages id is responsible for return ACK or NAK if required
    struct AP_Mission::Mission_Command cmd;     // general purpose mission command
    memset(&cmd, 0, sizeof(cmd));

    switch (msg->msgid) {

    case MAVLINK_MSG_ID_HEARTBEAT:      // MAV ID: 0
    {
        // We keep track of the last time we received a heartbeat from our GCS for failsafe purposes
        if(msg->sysid != g.sysid_my_gcs) break;
        failsafe.last_heartbeat_ms = millis();
        pmTest1++;
        break;
    }

    case MAVLINK_MSG_ID_SET_MODE:       // MAV ID: 11
    {
        // decode
        mavlink_set_mode_t packet;
        mavlink_msg_set_mode_decode(msg, &packet);

        // only accept custom modes because there is no easy mapping from Mavlink flight modes to AC flight modes
        if (packet.base_mode & MAV_MODE_FLAG_CUSTOM_MODE_ENABLED) {
            if (set_mode(packet.custom_mode)) {
                result = MAV_RESULT_ACCEPTED;
            }
        }

        // send ACK or NAK
        mavlink_msg_command_ack_send(chan, MAVLINK_MSG_ID_SET_MODE, result);
        break;
    }

    case MAVLINK_MSG_ID_PARAM_REQUEST_READ:         // MAV ID: 20
    {
        // decode
        mavlink_param_request_read_t packet;
        mavlink_msg_param_request_read_decode(msg, &packet);

        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system,packet.target_component)) {
            break;
        }

        enum ap_var_type p_type;
        AP_Param *vp;
        char param_name[AP_MAX_NAME_SIZE+1];
        if (packet.param_index != -1) {
            AP_Param::ParamToken token;
            vp = AP_Param::find_by_index(packet.param_index, &p_type, &token);
            if (vp == NULL) {
                gcs_send_text_fmt(PSTR("Unknown parameter index %d"), packet.param_index);
                break;
            }
            vp->copy_name_token(token, param_name, AP_MAX_NAME_SIZE, true);
            param_name[AP_MAX_NAME_SIZE] = 0;
        } else {
            strncpy(param_name, packet.param_id, AP_MAX_NAME_SIZE);
            param_name[AP_MAX_NAME_SIZE] = 0;
            vp = AP_Param::find(param_name, &p_type);
            if (vp == NULL) {
                gcs_send_text_fmt(PSTR("Unknown parameter %.16s"), packet.param_id);
                break;
            }
        }

        float value = vp->cast_to_float(p_type);
        mavlink_msg_param_value_send(
            chan,
            param_name,
            value,
            mav_var_type(p_type),
            _count_parameters(),
            packet.param_index);
        break;
    }

    case MAVLINK_MSG_ID_PARAM_REQUEST_LIST:         // MAV ID: 21
    {
        // decode
        mavlink_param_request_list_t packet;
        mavlink_msg_param_request_list_decode(msg, &packet);

        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system,packet.target_component)) {
            break;
        }

        // mark the firmware version in the tlog
        send_text_P(SEVERITY_LOW, PSTR(FIRMWARE_STRING));

#if defined(PX4_GIT_VERSION) && defined(NUTTX_GIT_VERSION)
        send_text_P(SEVERITY_LOW, PSTR("PX4: " PX4_GIT_VERSION " NuttX: " NUTTX_GIT_VERSION));
#endif

        // send system ID if we can
        char sysid[40];
        if (hal.util->get_system_id(sysid)) {
            mavlink_send_text(chan, SEVERITY_LOW, sysid);
        }

        // Start sending parameters - next call to ::update will kick the first one out
        _queued_parameter = AP_Param::first(&_queued_parameter_token, &_queued_parameter_type);
        _queued_parameter_index = 0;
        _queued_parameter_count = _count_parameters();
        break;
    }

    case MAVLINK_MSG_ID_PARAM_SET:     // 23
    {
        AP_Param                  *vp;
        enum ap_var_type var_type;

        // decode
        mavlink_param_set_t packet;
        mavlink_msg_param_set_decode(msg, &packet);

        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system, packet.target_component)) {
            break;
        }

        // set parameter

        char key[AP_MAX_NAME_SIZE+1];
        strncpy(key, (char *)packet.param_id, AP_MAX_NAME_SIZE);
        key[AP_MAX_NAME_SIZE] = 0;

        // find the requested parameter
        vp = AP_Param::find(key, &var_type);
        if ((NULL != vp) &&                                                                                     // exists
            !isnan(packet.param_value) &&                                                  // not nan
            !isinf(packet.param_value)) {                                                  // not inf

            // add a small amount before casting parameter values
            // from float to integer to avoid truncating to the
            // next lower integer value.
            float rounding_addition = 0.01;

            // handle variables with standard type IDs
            if (var_type == AP_PARAM_FLOAT) {
                ((AP_Float *)vp)->set_and_save(packet.param_value);
            } else if (var_type == AP_PARAM_INT32) {
                if (packet.param_value < 0) rounding_addition = -rounding_addition;
                float v = packet.param_value+rounding_addition;
                v = constrain_float(v, -2147483648.0, 2147483647.0);
                ((AP_Int32 *)vp)->set_and_save(v);
            } else if (var_type == AP_PARAM_INT16) {
                if (packet.param_value < 0) rounding_addition = -rounding_addition;
                float v = packet.param_value+rounding_addition;
                v = constrain_float(v, -32768, 32767);
                ((AP_Int16 *)vp)->set_and_save(v);
            } else if (var_type == AP_PARAM_INT8) {
                if (packet.param_value < 0) rounding_addition = -rounding_addition;
                float v = packet.param_value+rounding_addition;
                v = constrain_float(v, -128, 127);
                ((AP_Int8 *)vp)->set_and_save(v);
            } else {
                // we don't support mavlink set on this parameter
                break;
            }

            // Report back the new value if we accepted the change
            // we send the value we actually set, which could be
            // different from the value sent, in case someone sent
            // a fractional value to an integer type
            mavlink_msg_param_value_send(
                chan,
                key,
                vp->cast_to_float(var_type),
                mav_var_type(var_type),
                _count_parameters(),
                -1);                         // XXX we don't actually know what its index is...
            DataFlash.Log_Write_Parameter(key, vp->cast_to_float(var_type));
        }

        break;
    }

    case MAVLINK_MSG_ID_MISSION_WRITE_PARTIAL_LIST: // MAV ID: 38
    {
        // decode
        mavlink_mission_write_partial_list_t packet;
        mavlink_msg_mission_write_partial_list_decode(msg, &packet);

        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system,packet.target_component)) {
            break;
        }

        // start waypoint receiving
        if (packet.start_index > mission.num_commands() ||
            packet.end_index > mission.num_commands() ||
            packet.end_index < packet.start_index) {
            send_text_P(SEVERITY_LOW,PSTR("flight plan update rejected"));
            break;
        }

        waypoint_timelast_receive = millis();
        waypoint_timelast_request = 0;
        waypoint_receiving   = true;
        waypoint_request_i   = packet.start_index;
        waypoint_request_last= packet.end_index;
        break;
    }

#ifdef MAVLINK_MSG_ID_SET_MAG_OFFSETS
    case MAVLINK_MSG_ID_SET_MAG_OFFSETS:
    {
        mavlink_set_mag_offsets_t packet;
        mavlink_msg_set_mag_offsets_decode(msg, &packet);
        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system,packet.target_component)) {
            break;
        }
        compass.set_offsets(Vector3f(packet.mag_ofs_x, packet.mag_ofs_y, packet.mag_ofs_z));
        break;
    }
#endif

    // GCS has sent us a command from GCS, store to EEPROM
    case MAVLINK_MSG_ID_MISSION_ITEM:           // MAV ID: 39
    {
        // decode
        mavlink_mission_item_t packet;
        mavlink_msg_mission_item_decode(msg, &packet);

        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system,packet.target_component)) {
            break;
        }

        // convert mavlink packet to mission command
        if (!AP_Mission::mavlink_to_mission_cmd(packet, cmd)) {
            result = MAV_MISSION_ERROR;
            goto mission_item_receive_failed;
        }

        if(packet.current == 2) {   // current = 2 is a flag to tell us this is a "guided mode" waypoint and not for the mission
            // initiate guided mode
            if (do_guided(cmd)) {
                result = MAV_MISSION_ACCEPTED;
            }

            // send ACK or NAK
            mavlink_msg_mission_ack_send(chan, msg->sysid, msg->compid, result);

        } else if(packet.current == 3) {    //current = 3 is a flag to tell us this is a alt change only

            // add home alt if needed
            if (cmd.content.location.options & LOCATION_MASK_OPTIONS_RELATIVE_ALT) {
                cmd.content.location.alt += home.alt;
            }

            // To-Do: update target altitude for loiter or waypoint controller depending upon nav mode
            // similar to how do_change_alt works
            wp_nav.set_desired_alt(cmd.content.location.alt);

            // verify we received the command
            mavlink_msg_mission_ack_send(chan, msg->sysid, msg->compid, MAV_MISSION_ACCEPTED);

        } else {
            // Check if receiving waypoints (mission upload expected)
            if (!waypoint_receiving) {
                result = MAV_MISSION_ERROR;
                goto mission_item_receive_failed;
            }

            // check if this is the requested waypoint
            if (packet.seq != waypoint_request_i) {
                result = MAV_MISSION_INVALID_SEQUENCE;
                goto mission_item_receive_failed;
            }

            // if command index is within the existing list, replace the command
            if (packet.seq < mission.num_commands()) {
                if (mission.replace_cmd(packet.seq,cmd)) {
                    result = MAV_MISSION_ACCEPTED;
                }else{
                    result = MAV_MISSION_ERROR;
                    goto mission_item_receive_failed;
                }
            // if command is at the end of command list, add the command
            }else if (packet.seq == mission.num_commands()) {
                if (mission.add_cmd(cmd)) {
                    result = MAV_MISSION_ACCEPTED;
                }else{
                    result = MAV_MISSION_ERROR;
                    goto mission_item_receive_failed;
                }
            // if beyond the end of the command list, return an error
            }else{
                result = MAV_MISSION_ERROR;
                goto mission_item_receive_failed;
            }

            // update waypoint receiving state machine
            waypoint_timelast_receive = millis();
            waypoint_timelast_request = 0;
            waypoint_request_i++;

            // send mission ACK after receiving the last command
            if (waypoint_request_i >= waypoint_request_last) {
                mavlink_msg_mission_ack_send(chan, msg->sysid, msg->compid, result);

                send_text_P(SEVERITY_LOW,PSTR("flight plan received"));
                waypoint_receiving = false;
            }
        }
        break;

mission_item_receive_failed:
        // we are rejecting the mission/waypoint
        mavlink_msg_mission_ack_send(chan, msg->sysid, msg->compid, result);
        break;
    }

    // read an individual command from EEPROM and send it to the GCS
    case MAVLINK_MSG_ID_MISSION_REQUEST:     // MAV ID: 40
    {
        // decode
        mavlink_mission_request_t packet;
        mavlink_msg_mission_request_decode(msg, &packet);

        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system, packet.target_component)) {
            break;
        }

        // retrieve mission from eeprom
        if (!mission.read_cmd_from_storage(packet.seq, cmd)) {
            result = MAV_MISSION_ERROR;
            goto mission_item_send_failed;
        }

        // convert mission command to mavlink mission item packet
        mavlink_mission_item_t ret_packet;
        memset(&ret_packet, 0, sizeof(ret_packet));
        if (!AP_Mission::mission_cmd_to_mavlink(cmd, ret_packet)) {
            result = MAV_MISSION_ERROR;
            goto mission_item_send_failed;
        }

        // set packet's current field to 1 if this is the command being executed
        if (cmd.id == (uint16_t)mission.get_current_nav_cmd().index) {
            ret_packet.current = 1;
        }else{
            ret_packet.current = 0;
        }

        // set auto continue to 1
        ret_packet.autocontinue = 1;

        mavlink_msg_mission_item_send(chan,msg->sysid,
                                      msg->compid,
                                      packet.seq,
                                      ret_packet.frame,
                                      cmd.id,
                                      ret_packet.current,
                                      ret_packet.autocontinue,
                                      ret_packet.param1,
                                      ret_packet.param2,
                                      ret_packet.param3,
                                      ret_packet.param4,
                                      ret_packet.x,
                                      ret_packet.y,
                                      ret_packet.z);
        break;

mission_item_send_failed:
        // send failure message
        mavlink_msg_mission_ack_send(chan, msg->sysid, msg->compid, result);
        break;
    }

    case MAVLINK_MSG_ID_MISSION_SET_CURRENT:    // MAV ID: 41
    {
        // decode
        mavlink_mission_set_current_t packet;
        mavlink_msg_mission_set_current_decode(msg, &packet);

        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system,packet.target_component)) {
            break;
        }

        // set current command
        mission.set_current_cmd(packet.seq);

        mavlink_msg_mission_current_send(chan, mission.get_current_do_cmd().index);
        break;
    }

    // GCS request the full list of commands, we return just the number and leave the GCS to then request each command individually
    case MAVLINK_MSG_ID_MISSION_REQUEST_LIST:       // MAV ID: 43
    {
        // decode
        mavlink_mission_request_list_t packet;
        mavlink_msg_mission_request_list_decode(msg, &packet);

        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system, packet.target_component)) {
            break;
        }

        // reply with number of commands in the mission.  The GCS will then request each command separately
        mavlink_msg_mission_count_send(chan,msg->sysid, msg->compid, mission.num_commands());

        // set variables to help handle the expected sending of commands to the GCS
        waypoint_receiving = false;             // record that we are sending commands (i.e. not receiving)
        waypoint_dest_sysid = msg->sysid;       // record system id of GCS who has requested the commands
        waypoint_dest_compid = msg->compid;     // record component id of GCS who has requested the commands
        break;
    }

    // GCS provides the full number of commands it wishes to upload
    //  individual commands will then be sent from the GCS using the MAVLINK_MSG_ID_MISSION_ITEM message
    case MAVLINK_MSG_ID_MISSION_COUNT:          // MAV ID: 44
    {
        // decode
        mavlink_mission_count_t packet;
        mavlink_msg_mission_count_decode(msg, &packet);

        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system,packet.target_component)) {
            break;
        }

        // start waypoint receiving
        if (packet.count > AP_MISSION_MAX_COMMANDS) {
            // send NAK
            mavlink_msg_mission_ack_send(chan, msg->sysid, msg->compid, MAV_MISSION_NO_SPACE);
            break;
        }

        // new mission arriving, clear current mission
        if (!mission.clear()) {
            // return error if we were unable to clear the mission (possibly because we're currently flying the mission)
            mavlink_msg_mission_ack_send(chan, msg->sysid, msg->compid, MAV_MISSION_ERROR);
        }

        // set variables to help handle the expected receiving of commands from the GCS
        waypoint_timelast_receive = millis();   // set time we last received commands to now
        waypoint_receiving = true;              // record that we expect to receive commands
        waypoint_request_i = 0;                 // reset the next expected command number to zero
        waypoint_request_last = packet.count;   // record how many commands we expect to receive
        waypoint_timelast_request = 0;          // set time we last requested commands to zero
        break;
    }

    case MAVLINK_MSG_ID_MISSION_CLEAR_ALL:      // MAV ID: 45
    {
        // decode
        mavlink_mission_clear_all_t packet;
        mavlink_msg_mission_clear_all_decode(msg, &packet);

        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system, packet.target_component)) {
            break;
        }

        // clear all waypoints
        if (mission.clear()) {
            // send ack
            mavlink_msg_mission_ack_send(chan, msg->sysid, msg->compid, MAV_RESULT_ACCEPTED);
        }else{
            // send nack
            mavlink_msg_mission_ack_send(chan, msg->sysid, msg->compid, 1);
        }
        break;
    }

    case MAVLINK_MSG_ID_REQUEST_DATA_STREAM:    // MAV ID: 66
    {
        // decode
        mavlink_request_data_stream_t packet;
        mavlink_msg_request_data_stream_decode(msg, &packet);

        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system, packet.target_component)) {
            break;
        }

        int16_t freq = 0;                 // packet frequency

        if (packet.start_stop == 0) {
            freq = 0;                     // stop sending
        } else if (packet.start_stop == 1) {
            freq = packet.req_message_rate;                     // start sending
        } else {
            break;
        }

        switch(packet.req_stream_id) {

        case MAV_DATA_STREAM_ALL:
            // note that we don't set STREAM_PARAMS - that is internal only
            for (uint8_t i=0; i<STREAM_PARAMS; i++) {
                streamRates[i].set(freq);
            }
            break;
        case MAV_DATA_STREAM_RAW_SENSORS:
            streamRates[STREAM_RAW_SENSORS].set(freq);
            break;
        case MAV_DATA_STREAM_EXTENDED_STATUS:
            streamRates[STREAM_EXTENDED_STATUS].set(freq);
            break;
        case MAV_DATA_STREAM_RC_CHANNELS:
            streamRates[STREAM_RC_CHANNELS].set(freq);
            break;
        case MAV_DATA_STREAM_RAW_CONTROLLER:
            streamRates[STREAM_RAW_CONTROLLER].set(freq);
            break;
        case MAV_DATA_STREAM_POSITION:
            streamRates[STREAM_POSITION].set(freq);
            break;
        case MAV_DATA_STREAM_EXTRA1:
            streamRates[STREAM_EXTRA1].set(freq);
            break;
        case MAV_DATA_STREAM_EXTRA2:
            streamRates[STREAM_EXTRA2].set(freq);
            break;
        case MAV_DATA_STREAM_EXTRA3:
            streamRates[STREAM_EXTRA3].set(freq);
            break;
        }
        break;
    }

    case MAVLINK_MSG_ID_RC_CHANNELS_OVERRIDE:       // MAV ID: 70
    {
        // allow override of RC channel values for HIL
        // or for complete GCS control of switch position
        // and RC PWM values.
        if(msg->sysid != g.sysid_my_gcs) break;                         // Only accept control from our gcs
        mavlink_rc_channels_override_t packet;
        int16_t v[8];
        mavlink_msg_rc_channels_override_decode(msg, &packet);

        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system,packet.target_component)) {
            break;
        }

        v[0] = packet.chan1_raw;
        v[1] = packet.chan2_raw;
        v[2] = packet.chan3_raw;
        v[3] = packet.chan4_raw;
        v[4] = packet.chan5_raw;
        v[5] = packet.chan6_raw;
        v[6] = packet.chan7_raw;
        v[7] = packet.chan8_raw;
        hal.rcin->set_overrides(v, 8);

        // record that rc are overwritten so we can trigger a failsafe if we lose contact with groundstation
        failsafe.rc_override_active = true;
        // a RC override message is consiered to be a 'heartbeat' from the ground station for failsafe purposes
        failsafe.last_heartbeat_ms = millis();
        break;
    }

    // Pre-Flight calibration requests
    case MAVLINK_MSG_ID_COMMAND_LONG:       // MAV ID: 76
    {
        // decode packet
        mavlink_command_long_t packet;
        mavlink_msg_command_long_decode(msg, &packet);

        // exit immediately if this command is not meant for this vehicle
        if (mavlink_check_target(packet.target_system, packet.target_component)) {
            break;
        }

        switch(packet.command) {

        case MAV_CMD_NAV_LOITER_UNLIM:
            if (set_mode(LOITER)) {
                result = MAV_RESULT_ACCEPTED;
            }
            break;

        case MAV_CMD_NAV_RETURN_TO_LAUNCH:
            if (set_mode(RTL)) {
                result = MAV_RESULT_ACCEPTED;
            }
            break;

        case MAV_CMD_NAV_LAND:
            if (set_mode(LAND)) {
                result = MAV_RESULT_ACCEPTED;
            }
            break;

        case MAV_CMD_MISSION_START:
            if (set_mode(AUTO)) {
                result = MAV_RESULT_ACCEPTED;
            }
            break;

        case MAV_CMD_PREFLIGHT_CALIBRATION:
            if (packet.param1 == 1 ||
                packet.param2 == 1) {
                ins.init_accel();
                ahrs.set_trim(Vector3f(0,0,0));             // clear out saved trim
                result = MAV_RESULT_ACCEPTED;
            }
            if (packet.param3 == 1) {
                init_barometer(false);                      // fast barometer calibration
                result = MAV_RESULT_ACCEPTED;
            }
            if (packet.param4 == 1) {
                trim_radio();
                result = MAV_RESULT_ACCEPTED;
            }
            if (packet.param5 == 1) {
                float trim_roll, trim_pitch;
                // this blocks
                AP_InertialSensor_UserInteract_MAVLink interact(chan);
                if(ins.calibrate_accel(&interact, trim_roll, trim_pitch)) {
                    // reset ahrs's trim to suggested values from calibration routine
                    ahrs.set_trim(Vector3f(trim_roll, trim_pitch, 0));
                }
                result = MAV_RESULT_ACCEPTED;
            }
            if (packet.param6 == 1) {
                // compassmot calibration
                result = mavlink_compassmot(chan);
            }
            break;

        case MAV_CMD_COMPONENT_ARM_DISARM:
            if (packet.target_component == MAV_COMP_ID_SYSTEM_CONTROL) {
                if (packet.param1 == 1.0f) {
                    // run pre_arm_checks and arm_checks and display failures
                    pre_arm_checks(true);
                    if(ap.pre_arm_check && arm_checks(true)) {
                        init_arm_motors();
                        result = MAV_RESULT_ACCEPTED;
                    }else{
                        result = MAV_RESULT_UNSUPPORTED;
                    }
                } else if (packet.param1 == 0.0f)  {
                    init_disarm_motors();
                    result = MAV_RESULT_ACCEPTED;
                } else {
                    result = MAV_RESULT_UNSUPPORTED;
                }
            } else {
                result = MAV_RESULT_UNSUPPORTED;
            }
            break;

        case MAV_CMD_DO_SET_SERVO:
            if (ServoRelayEvents.do_set_servo(packet.param1, packet.param2)) {
                result = MAV_RESULT_ACCEPTED;
            }
            break;

        case MAV_CMD_DO_REPEAT_SERVO:
            if (ServoRelayEvents.do_repeat_servo(packet.param1, packet.param2, packet.param3, packet.param4*1000)) {
                result = MAV_RESULT_ACCEPTED;
            }
            break;

        case MAV_CMD_DO_SET_RELAY:
            if (ServoRelayEvents.do_set_relay(packet.param1, packet.param2)) {
                result = MAV_RESULT_ACCEPTED;
            }
            break;

        case MAV_CMD_DO_REPEAT_RELAY:
            if (ServoRelayEvents.do_repeat_relay(packet.param1, packet.param2, packet.param3*1000)) {
                result = MAV_RESULT_ACCEPTED;
            }
            break;

        case MAV_CMD_PREFLIGHT_REBOOT_SHUTDOWN:
            if (packet.param1 == 1 || packet.param1 == 3) {
                // when packet.param1 == 3 we reboot to hold in bootloader
                hal.scheduler->reboot(packet.param1 == 3);
                result = MAV_RESULT_ACCEPTED;
            }
            break;

        default:
            result = MAV_RESULT_UNSUPPORTED;
            break;
        }

        // send ACK or NAK
        mavlink_msg_command_ack_send(chan, packet.command, result);

        break;
    }

    case MAVLINK_MSG_ID_COMMAND_ACK:        // MAV ID: 77
    {
        command_ack_counter++;
        break;
    }

#if HIL_MODE != HIL_MODE_DISABLED
    case MAVLINK_MSG_ID_HIL_STATE:          // MAV ID: 90
    {
        mavlink_hil_state_t packet;
        mavlink_msg_hil_state_decode(msg, &packet);

        float vel = pythagorous2(packet.vx, packet.vy);
        float cog = wrap_360_cd(ToDeg(atan2f(packet.vx, packet.vy)) * 100);

        // if we are erasing the dataflash this object doesnt exist yet. as its called from delay_cb
        if (g_gps == NULL)
            break;

        // set gps hil sensor
        g_gps->setHIL(GPS::FIX_3D,
                      packet.time_usec/1000,
                      packet.lat*1.0e-7, packet.lon*1.0e-7, packet.alt*1.0e-3,
                      vel*1.0e-2, cog*1.0e-2, 0, 10);

        if (!ap.home_is_set) {
            init_home();
        }


        // rad/sec
        Vector3f gyros;
        gyros.x = packet.rollspeed;
        gyros.y = packet.pitchspeed;
        gyros.z = packet.yawspeed;

        // m/s/s
        Vector3f accels;
        accels.x = packet.xacc * (GRAVITY_MSS/1000.0);
        accels.y = packet.yacc * (GRAVITY_MSS/1000.0);
        accels.z = packet.zacc * (GRAVITY_MSS/1000.0);

        ins.set_gyro(0, gyros);

        ins.set_accel(0, accels);

        barometer.setHIL(packet.alt*0.001f);
        compass.setHIL(packet.roll, packet.pitch, packet.yaw);

        break;
    }
#endif //  HIL_MODE != HIL_MODE_DISABLED

    case MAVLINK_MSG_ID_RADIO:
    case MAVLINK_MSG_ID_RADIO_STATUS:       // MAV ID: 109
    {
        mavlink_radio_t packet;
        mavlink_msg_radio_decode(msg, &packet);
        // use the state of the transmit buffer in the radio to
        // control the stream rate, giving us adaptive software
        // flow control
        if (packet.txbuf < 20 && stream_slowdown < 100) {
            // we are very low on space - slow down a lot
            stream_slowdown += 3;
        } else if (packet.txbuf < 50 && stream_slowdown < 100) {
            // we are a bit low on space, slow down slightly
            stream_slowdown += 1;
        } else if (packet.txbuf > 95 && stream_slowdown > 10) {
            // the buffer has plenty of space, speed up a lot
            stream_slowdown -= 2;
        } else if (packet.txbuf > 90 && stream_slowdown != 0) {
            // the buffer has enough space, speed up a bit
            stream_slowdown--;
        }
        break;
    }

    case MAVLINK_MSG_ID_LOG_REQUEST_LIST ... MAVLINK_MSG_ID_LOG_REQUEST_END:    // MAV ID: 117 ... 122
        if (!in_mavlink_delay && !motors.armed()) {
            handle_log_message(msg, DataFlash);
        }
        break;

#if CAMERA == ENABLED
    case MAVLINK_MSG_ID_DIGICAM_CONFIGURE:      // MAV ID: 202
        camera.configure_msg(msg);
        break;

    case MAVLINK_MSG_ID_DIGICAM_CONTROL:
        camera.control_msg(msg);
        break;
#endif // CAMERA == ENABLED

#if MOUNT == ENABLED
    case MAVLINK_MSG_ID_MOUNT_CONFIGURE:        // MAV ID: 204
        camera_mount.configure_msg(msg);
        break;

    case MAVLINK_MSG_ID_MOUNT_CONTROL:
        camera_mount.control_msg(msg);
        break;

    case MAVLINK_MSG_ID_MOUNT_STATUS:
        camera_mount.status_msg(msg);
        break;
#endif // MOUNT == ENABLED
    }     // end switch
} // end handle mavlink


/*
 *  a delay() callback that processes MAVLink packets. We set this as the
 *  callback in long running library initialisation routines to allow
 *  MAVLink to process packets while waiting for the initialisation to
 *  complete
 */
static void mavlink_delay_cb()
{
    static uint32_t last_1hz, last_50hz, last_5s;
    if (!gcs[0].initialised || in_mavlink_delay) return;

    in_mavlink_delay = true;

    uint32_t tnow = millis();
    if (tnow - last_1hz > 1000) {
        last_1hz = tnow;
        gcs_send_heartbeat();
        gcs_send_message(MSG_EXTENDED_STATUS1);
    }
    if (tnow - last_50hz > 20) {
        last_50hz = tnow;
        gcs_check_input();
        gcs_data_stream_send();
        gcs_send_deferred();
        notify.update();
    }
    if (tnow - last_5s > 5000) {
        last_5s = tnow;
        gcs_send_text_P(SEVERITY_LOW, PSTR("Initialising APM..."));
    }
    check_usb_mux();

    in_mavlink_delay = false;
}

/*
 *  send a message on both GCS links
 */
static void gcs_send_message(enum ap_message id)
{
    for (uint8_t i=0; i<num_gcs; i++) {
        if (gcs[i].initialised) {
            gcs[i].send_message(id);
        }
    }
}

/*
 *  send data streams in the given rate range on both links
 */
static void gcs_data_stream_send(void)
{
    for (uint8_t i=0; i<num_gcs; i++) {
        if (gcs[i].initialised) {
            gcs[i].data_stream_send();
        }
    }
}

/*
 *  look for incoming commands on the GCS links
 */
static void gcs_check_input(void)
{
    for (uint8_t i=0; i<num_gcs; i++) {
        if (gcs[i].initialised) {
            gcs[i].update();
        }
    }
}

static void gcs_send_text_P(gcs_severity severity, const prog_char_t *str)
{
    for (uint8_t i=0; i<num_gcs; i++) {
        if (gcs[i].initialised) {
            gcs[i].send_text_P(severity, str);
        }
    }
}

/*
 *  send a low priority formatted message to the GCS
 *  only one fits in the queue, so if you send more than one before the
 *  last one gets into the serial buffer then the old one will be lost
 */
void gcs_send_text_fmt(const prog_char_t *fmt, ...)
{
    va_list arg_list;
    gcs[0].pending_status.severity = (uint8_t)SEVERITY_LOW;
    va_start(arg_list, fmt);
    hal.util->vsnprintf_P((char *)gcs[0].pending_status.text,
            sizeof(gcs[0].pending_status.text), fmt, arg_list);
    va_end(arg_list);
    mavlink_send_message(MAVLINK_COMM_0, MSG_STATUSTEXT, 0);
    for (uint8_t i=1; i<num_gcs; i++) {
        if (gcs[i].initialised) {
            gcs[i].pending_status = gcs[0].pending_status;
            mavlink_send_message((mavlink_channel_t)i, MSG_STATUSTEXT, 0);
        }
    }
}
