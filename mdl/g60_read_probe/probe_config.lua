-- Center mode never adds a fixed height. Fallback is identified on the HUD.
return {center_fallback_to_network=true,early_terminal_slot3=true,source_max_age=.15,target_max_age=.15,source_interval=.025,target_interval=.05,
 estimation={candidate_radius_m=200,sample_interval_s=.1,minimum_history_s=.2,confirm_s=.3,
 candidate_freshness_s=.35,minimum_speed_m_s=1,maximum_speed_m_s=120,
 minimum_alignment=.94,minimum_score=.65,minimum_margin=.08}}
