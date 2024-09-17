current_velocity: f32 = 0,
smooth_time: f32 = 0.1,
max_speed: f32 = 40,

pub fn damp(self: *@This(), value: f32, target: f32, delta_time: f32) f32 {
    return smoothDamp(value, target, &self.current_velocity, self.smooth_time, self.max_speed, delta_time);
}

// https://stackoverflow.com/questions/61372498/how-does-mathf-smoothdamp-work-what-is-it-algorithm
fn smoothDamp(current: f32, target_: f32, current_velocity: *f32, smooth_time_: f32, max_speed: f32, delta_time: f32) f32 {
    const smooth_time = @max(0.0001, smooth_time_);
    var target = target_;

    const omega = 2 / smooth_time;

    const x = omega * delta_time;
    const exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x);
    var change = current - target;
    const original_to = target;

    const max_change = max_speed * smooth_time;
    change = clamp(change, -max_change, max_change);
    target = current - change;

    const temp = (current_velocity.* + omega * change) * delta_time;
    current_velocity.* = (current_velocity.* - omega * temp) * exp;
    var output = target + (change + temp) * exp;

    if (original_to - current > 0 and output > original_to) {
        output = original_to;
        current_velocity.* = (output - original_to) / delta_time;
    }

    return output;
}

fn clamp(value: f32, min: f32, max: f32) f32 {
    var result: f32 = if (value < min) min else value;
    if (result > max) result = max;
    return result;
}
