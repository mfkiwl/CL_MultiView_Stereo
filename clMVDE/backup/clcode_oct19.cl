kernel void Init(global unsigned char *img_dev, global float *lab_dev)
{
	int width  = get_global_size(0);
	int height = get_global_size(1);
	
	int col    = get_global_id(0);
	int row    = get_global_id(1);
	int page   = get_global_id(2);
	
	int tid = page*width*height + row*width + col;

	lab_dev[tid] = 9; 
}



float3 rgb2lab(uchar3 pix_in)
{
	float3 pix_out;
	
	float _b = (float)pix_in.s0 * 0.0039216f;
	float _g = (float)pix_in.s1 * 0.0039216f;
	float _r = (float)pix_in.s2 * 0.0039216f;

	float x = _r*0.412453f + _g*0.357580f + _b*0.180423f;
	float y = _r*0.212671f + _g*0.715160f + _b*0.072169f;
	float z = _r*0.019334f + _g*0.119193f + _b*0.950227f;

	float epsilon = 0.008856f;	//actual CIE standard
	float kappa = 903.3f;		//actual CIE standard

	float Xr = 0.950456f;	//reference white
	float Yr = 1.0f;		//reference white
	float Zr = 1.088754f;	//reference white

	float xr = x / Xr;
	float yr = y / Yr;
	float zr = z / Zr;

	float fx, fy, fz;
	if (xr > epsilon)	fx = powr(xr, 1.0f / 3.0f);
	else				fx = (kappa*xr + 16.0f) / 116.0f;
	if (yr > epsilon)	fy = powr(yr, 1.0f / 3.0f);
	else				fy = (kappa*yr + 16.0f) / 116.0f;
	if (zr > epsilon)	fz = powr(zr, 1.0f / 3.0f);
	else				fz = (kappa*zr + 16.0f) / 116.0f;

	
	pix_out.s0 = 116.0f*fy - 16.0f;
	pix_out.s1 = 500.0f*(fx - fy);
	pix_out.s2 = 200.0f*(fy - fz);
	
	return pix_out;
		
}




kernel void cvt(global uchar3 *img_dev, global float3 *lab_dev, int2 img_size)
{
	
	int col    = get_global_id(0);
	int row    = get_global_id(1);
	
	if (col >= img_size.x || row >= img_size.y)
		return;
	
	int width  = img_size.x; //get_global_size(0);
	int height = img_size.y; //get_global_size(1);
	
	int tid    = width*row + col;
	
	float3 temp;
	uchar3 pix_in = img_dev[tid];
	temp = rgb2lab(pix_in);
	
	lab_dev[tid].s0 = temp.s0;
	lab_dev[tid].s1 = temp.s1;
	lab_dev[tid].s2 = temp.s2;
	
}



kernel void init_cluster_centers(global float3 *lab_dev, global float8 *spixel_map, 
int2 img_size, int2 map_size, int spixel_size)
{
	int col = get_global_id(0);
	int row = get_global_id(1);
	
	if (col >= map_size.x || row >= map_size.y)
		return;
	
	int cluster_idx   = row * map_size.x + col;
	
	int center_x = col * spixel_size + spixel_size / 2;
	int center_y = row * spixel_size + spixel_size / 2;
	
	if (center_x > img_size.s0)
		center_x = (col * spixel_size + img_size.s0) / 2;
	
	if (center_y > img_size.s1)
		center_y = (row * spixel_size + img_size.s1) / 2;
	
	float cluster_idx_f = (float)cluster_idx;
	float center_x_f    = (float)center_x;
	float center_y_f    = (float)center_y;
	
	
	
	spixel_map[cluster_idx].s0 = cluster_idx_f;				// Assigning the ID.
	spixel_map[cluster_idx].s1 = center_x_f;				// Assigning the x coordinate.
	spixel_map[cluster_idx].s2 = center_y_f;				// Assigning the y coordinate.
	
	spixel_map[cluster_idx].s3 = lab_dev[center_y*img_size.s0 + center_x].s0; // Assigning the color info: L component.
	spixel_map[cluster_idx].s4 = lab_dev[center_y*img_size.s0 + center_x].s1; // Assigning the color info: A component.
	spixel_map[cluster_idx].s5 = lab_dev[center_y*img_size.s0 + center_x].s2; // Assigning the color info: B component.
	
	spixel_map[cluster_idx].s6 = 0.0;
}




float slic_distance_function(float3 pixel, int y, int x, float8 cluster, float weight, float space_normalizer, float color_normalizer)
{
	
	float color_distance = (pixel.x - cluster.s3) * (pixel.x - cluster.s3)
						 + (pixel.y - cluster.s4) * (pixel.y - cluster.s4)
						 + (pixel.z - cluster.s5) * (pixel.z - cluster.s5);
	
	float space_distance = (x - cluster.s1) * (x - cluster.s1)
						 + (y - cluster.s2) * (y - cluster.s2);


	float distance = (color_distance * color_normalizer) + weight*(space_distance * space_normalizer);
	
	return sqrt(distance);
	//return sqrt(distance);
	
}



kernel void find_center_association(global float3 *lab_dev, global float8 *spixel_map, 
global unsigned int *idx_img_dev, int2 img_size, int2 map_size, int spixel_size, 
float max_xy_dist, float max_color_dist, float weight)
{
	int col = get_global_id(0);
	int row = get_global_id(1);
	
	if (col >= img_size.x || row >= img_size.y)
		return; 
	
	//int width = img_size.x;//get_global_size(0);
	
	int pixel_id = row * img_size.x + col;
	
	int cluster_x = col / spixel_size;
	int cluster_y = row / spixel_size;
	
	float min_dist = 999999.9999f;
	float min_id = -1;
	
	for (int i = -1 ; i <= 1 ; i++)
		for (int j = -1 ; j <= 1 ; j++)
		{
			int cluster_idx_x = cluster_x + j;
			int cluster_idx_y = cluster_y + i;
			
			if (cluster_idx_x >= 0 && cluster_idx_y >= 0 && cluster_idx_x < map_size.x && cluster_idx_y < map_size.y)	
			{
				int cluster_idx = cluster_idx_y * map_size.x + cluster_idx_x;
				
				float dist = slic_distance_function(lab_dev[pixel_id], row, col, spixel_map[cluster_idx], weight, max_xy_dist, max_color_dist);
				
				if (dist < min_dist)
				{
					min_dist = dist;
					min_id	 = cluster_idx;//spixel_map[cluster_idx].s0;
				}
			}
				
		}
	unsigned int min_id_uint = (unsigned int) min_id; 
	idx_img_dev[pixel_id] = min_id_uint; 	
}



kernel void update_cluster_center(global float3 *lab_dev, global uint *idx_img_dev, global float8 *accum_map_dev,
int2 map_size, int2 img_size, int spixel_size, int num_cluster_per_line, local float3 *color_local, local float2 *location_local, local float *count_local, local bool *should_add)
{
	
	int local_idx = get_local_id(1) * get_local_size(0) + get_local_id(0);
	
	// Initialize local (shared) memory arrays
	color_local[local_idx].s0 = 0.0; color_local[local_idx].s1 = 0.0; color_local[local_idx].s2 = 0.0;
	location_local[local_idx] = (float2)(0.0, 0.0);
	count_local[local_idx] = 0.0;
	*should_add = false;
	barrier(CLK_LOCAL_MEM_FENCE);
	
	int num_group_per_cluster = get_global_size(2);
	
	// Compute the id of each super-pixel
	int spixel_idx = get_group_id(1) * map_size.x + get_group_id(0);
	
	// Compute the relative position in the search neighborhood.
	int nbr_x = get_group_id(2) % num_cluster_per_line;
	int nbr_y = get_group_id(2) / num_cluster_per_line;
	
	int px_offset = nbr_x * get_local_size(0) + get_local_id(0);
	int py_offset = nbr_y * get_local_size(1) + get_local_id(1);
	
	if (py_offset < spixel_size * 3 && px_offset < spixel_size * 3)
	{
		int px_start = get_group_id(0) * spixel_size - spixel_size;
		int py_start = get_group_id(1) * spixel_size - spixel_size;
		
		int px = px_start + px_offset;
		int py = py_start + py_offset;
		
		if (py >= 0 && px >= 0 && px < img_size.x && py < img_size.y)
		{
			int pixl_idx = py * img_size.x + px;
			
			if (idx_img_dev[pixl_idx] == spixel_idx)
			{	
				color_local[local_idx] = lab_dev[pixl_idx];
				location_local[local_idx] = (float2) ((float) px, (float) py);
				count_local[local_idx] = 1.0;
				*should_add = true;
			}
		}	
	}
	barrier(CLK_LOCAL_MEM_FENCE);
	
	
	if (should_add)
	{
		int i = 128;
		while (i != 0)
		{
			if (local_idx < i)
			{
				color_local[local_idx] += color_local[local_idx + i];
				location_local[local_idx] += location_local[local_idx + i];
				count_local[local_idx] += count_local[local_idx + i];
			}
			barrier(CLK_LOCAL_MEM_FENCE);
			
			i /= 2;
		}
	}
	
	
	if (local_idx == 0)  
	{
		int accum_map_idx = spixel_idx * num_group_per_cluster + get_group_id(2);
		
		accum_map_dev[accum_map_idx].s0   = spixel_idx;
		accum_map_dev[accum_map_idx].s12  = location_local[local_idx];
		accum_map_dev[accum_map_idx].s345 = color_local[local_idx];
		accum_map_dev[accum_map_idx].s6   = count_local[local_idx];
	}
	barrier(CLK_LOCAL_MEM_FENCE);
		
}



kernel void finalize_reduction_result(global float8 *accum_map_dev, global float8 *spixel_map_dev, int2 map_size, int num_group_per_cluster)
{
	
	int col = get_global_id(0);
	int row = get_global_id(1);
	
	if (col >= map_size.x || row >= map_size.y)
		return;
	
	
	int spixel_idx = row * map_size.x + col;
	
	spixel_map_dev[spixel_idx].s0 = (float)spixel_idx;
	spixel_map_dev[spixel_idx].s12 = (float2) (0.0, 0.0);		// Location component
	spixel_map_dev[spixel_idx].s345 = (float3) (0.0, 0.0, 0.0); // Color component	
	spixel_map_dev[spixel_idx].s6 = 0.0;						//count
	
	
	float2 xy = (float2)(0.0, 0.0);
	float3 color = (float3)(0.0, 0.0, 0.0);
	float n = 0.0;
	
	for (int i = 0 ; i < num_group_per_cluster ; i++)
	{
		int accum_idx = spixel_idx * num_group_per_cluster + i;
		float8 accum_val = accum_map_dev[accum_idx];
		
		xy.x  += accum_val.s1;	// Sum over locations
		xy.y  += accum_val.s2; 
		
		color.x = color.x + accum_val.s3;	// Sum over color components
		color.y = color.y + accum_val.s4;
		color.z = color.z + accum_val.s5;
		
		n  += accum_val.s6;	// Sum over number of pixels
	}
	
	if (n != 0)
	{
		xy  = (float2)(xy.x / n, xy.y / n);
		color = (float3)(color.x / n, color.y / n, color.z / n);
		
		spixel_map_dev[spixel_idx].s12  = xy;
		spixel_map_dev[spixel_idx].s345 = color;
		spixel_map_dev[spixel_idx].s6 = n;
		
		//spixel_map_dev[spixel_idx].s1 /= spixel_map_dev[spixel_idx].s6;
		//spixel_map_dev[spixel_idx].s2 /= spixel_map_dev[spixel_idx].s6;
		
		//spixel_map_dev[spixel_idx].s3 /= spixel_map_dev[spixel_idx].s6;
		//spixel_map_dev[spixel_idx].s4 /= spixel_map_dev[spixel_idx].s6;
		//spixel_map_dev[spixel_idx].s5 /= spixel_map_dev[spixel_idx].s6;
	}

}




/*float when_gt(float x, float y) 
{
	return fmax(sign(x - y), 0.0);
}
*/

////////////////////////// photo consistency depth initialization //////////////////////////

kernel void find_super_pixel_boundary(global float8 *spixl_map, global uint *idx_img, global uchar8 *spixl_rep, int2 map_size, int2 img_size, int spixl_size)
{
	int tid_x = get_global_id(0);
	int tid_y = get_global_id(1);
	int tid_z = get_global_id(2);
	
	if (tid_x > map_size.x - 1 || tid_y > map_size.y - 1)
		return;
	
	
	//int view_num = get_global_size(2);
		
	float center_x_f =  spixl_map[tid_z*map_size.x*map_size.y  + tid_y*map_size.x + tid_x].s1;
	float center_y_f =  spixl_map[tid_z*map_size.x*map_size.y + tid_y*map_size.x + tid_x].s2;
	
	int center_x = (int) center_x_f;
	int center_y = (int) center_y_f;
	
	if (center_x < spixl_size)
		center_x += (spixl_size - center_x);
	
	if (center_x + spixl_size > img_size.x )
		center_x -= spixl_size;
	
	if (center_y < spixl_size)
		center_y += (spixl_size - center_y);
	
	if (center_y + spixl_size > img_size.y )
		center_y -= spixl_size;
	
	int sp_idx = tid_y * map_size.x + tid_x;
	
	uchar8 dir = (uchar8) (0, 0, 0, 0, 0, 0, 0, 0);
	
	/**/
	for ( int i = 1 ; i < spixl_size ; i++)
	{
		if (sp_idx == idx_img[tid_z*img_size.s1*img_size.s0 + (center_y - i)*img_size.s0 + center_x - i] && center_x - i >= 0 && center_y - i >= 0)
			dir.s0 = i-1;	// nw
		
		if (sp_idx == idx_img[tid_z*img_size.s1*img_size.s0 + (center_y)*img_size.s0 + center_x - i] && center_x - i >= 0)
			dir.s1 = i-1;	// w
		
		if (sp_idx == idx_img[tid_z*img_size.s1*img_size.s0 + (center_y + i)*img_size.s0 + center_x - i] && center_x - i >= 0 && center_y + i < img_size.s1)
			dir.s2 = i-1;	// sw
		
		if (sp_idx == idx_img[tid_z*img_size.s1*img_size.s0 + (center_y - i)*img_size.s0 + center_x] && center_y - i >= 0 )
			dir.s3 = i-1;	//n
		
		if (sp_idx == idx_img[tid_z*img_size.s1*img_size.s0 + (center_y + i)*img_size.s0 + center_x] && center_y + i < img_size.s1)
			dir.s4 = i-1;	//s
			
		if (sp_idx == idx_img[tid_z*img_size.s1*img_size.s0 + (center_y - i)*img_size.s0 + center_x + i] && center_x + i < img_size.s0 && center_y - i >= 0)
			dir.s5 = i-1;	//ne
		
		if (sp_idx == idx_img[tid_z*img_size.s1*img_size.s0 + center_y*img_size.s0 + center_x + i] && center_x + i < img_size.s0)
			dir.s6 = i-1;	//e
		
		if (sp_idx == idx_img[tid_z*img_size.s1*img_size.s0 + (center_y + i)*img_size.s0 + center_x + i] && center_x + i < img_size.s0 && center_y + i < img_size.s1)
			dir.s7 = i-1;	//se
	}

	spixl_rep[tid_z*map_size.x*map_size.y + tid_y*map_size.x + tid_x] = dir;
	
}




void compute_cost_volume(
global float3 *cvt_img, 
global float8 *spixl_map,  
global float *disp_level, 
global int *view_subset, 
global int *subset_num, 
int array_width, int2 map_size, 
int2 img_size, float bl_ratio,
int sp_size, int num_disp, float2 step,
int x, int y, int z, int view_count
)
{
	barrier(CLK_GLOBAL_MEM_FENCE);
	
	int idx = map_size.x * map_size.y * z + map_size.x * y + x;
	
	float8 spixl = spixl_map[idx];
	float2 center = spixl.s12;
	int2 camIdx  = (int2)(z % array_width, z / array_width);
	float cost_est = 1000000.0, disp_est = 0.0;
	
	
	for (int dl = 0 ; dl < num_disp ; dl++)
	{
		float d = disp_level[dl];
		float min_val = 1000000.0;
		
		for (int n = 0 ; n < subset_num[z] ; n++)
		{
			int view = view_subset[n];
			int2 viewIdx = (int2)(view % array_width, view / array_width);
			float val = 0.0;
			
			for (int i = -2 ; i <= 2 ; i++) for (int j = -2 ; j <= 2 ; j++)
			{
				//int2 xy_ref = (int2)(center.x - 2*step.x + i*step.x, center.y - 2*step.y + j*step.y);
				int2 xy_ref = (int2)(center.x + i*step.x, center.y + j*step.y);
				int2 xy_proj = (int2)((int)(xy_ref.x - d*(viewIdx.x - camIdx.x)), (int)(xy_ref.y - bl_ratio*d*(viewIdx.y - camIdx.y) ) );					
			
				if (xy_ref.x >= 0 && xy_ref.y >= 0 && xy_proj.x >= 0 && xy_proj.y >= 0 && xy_ref.x < img_size.x && xy_ref.y < img_size.y && xy_proj.x < img_size.x  && xy_proj.y < img_size.y)
				{
					float3 color_ref  = cvt_img[img_size.x*img_size.y*z     + img_size.x*xy_ref.y  + xy_ref.x];
					float3 color_proj = cvt_img[img_size.x*img_size.y*view  + img_size.x*xy_proj.y + xy_proj.x];
					val += fabs(color_ref.x - color_proj.x) + fabs(color_ref.y - color_proj.y) + fabs(color_ref.z - color_proj.z);
				}
				else 
					val += 30;
			}
			if (val < min_val)
				min_val = val;
		}
		if (min_val < cost_est)
		{
			cost_est = min_val;
			disp_est = d;
		}
	}
	
	spixl_map[idx].s7 = disp_est;
}




kernel void initial_depth_estimation(
global float3 *cvt_img, 
global float8 *spixl_map, 
global uchar8 *spixl_rep,
global uint *idx_img, 
global float *disp_level, 
global int *view_subset, 
global int *subset_num, 
int array_width, int2 map_size, 
int2 img_size, float bl_ratio,
int sp_size, int num_disp
)
{
	int x = get_global_id(0);
	int y = get_global_id(1);
	//int z = get_global_id(2);
	if (x >= map_size.x || y >= map_size.y)
		return;
	
	/**/
	//float2 step = (float2)(1, 1);
	for (int z = 0 ; z < 15 ; z++){
		
		int idx = map_size.x * map_size.y * z + map_size.x * y + x;
	
		// Set the bounding box
		/**/
		uchar8 dir = (uchar8) (0, 0, 0, 0, 0, 0, 0, 0);
		dir = spixl_rep[idx];
		
		int bb_l = max((int)dir.s0, max((int)(dir.s1), (int)(dir.s2) ) );
		int bb_r = max((int)dir.s5, max((int)(dir.s6), (int)(dir.s7) ) );
		int bb_t = max((int)dir.s0, max((int)(dir.s3), (int)(dir.s5) ) );
		int bb_b = max((int)dir.s2, max((int)(dir.s4), (int)(dir.s7) ) );
		
		float2 step = (float2)(1, 1);
		step.x = fmax(1.0, 0.25*(float)(bb_l + bb_r) );
		step.y = fmax(1.0, 0.25*(float)(bb_t + bb_b) );
		
		compute_cost_volume(cvt_img, spixl_map, disp_level, view_subset, subset_num, 
										array_width, map_size, img_size, bl_ratio, sp_size, num_disp, step, x, y, z, 15);
		barrier(CLK_LOCAL_MEM_FENCE);
	}
	
}





kernel void initial_depth_estimation_v2(
global float3 *cvt_img, 
global float8 *spixl_map,
global uchar8 *spixl_rep,
global uint *idx_img,
global float *disp_level,
global int *view_subset, 
global int *subset_num,
int array_width, int2 map_size, 
int2 img_size, float bl_ratio,
int spixl_size, int disp_num,
int view_count, int z
)
{
	int x = get_global_id(0);
	int y = get_global_id(1);
	
	if (x >= map_size.x || y >= map_size.y)
		return;
	
	int idx = (map_size.x*map_size.y*z) + (map_size.x*y)+ x;
	
	//////////////////////////////////////////////////
	/////////////// Compute the Step ////////////////
	////////////////////////////////////////////////
	uchar8 dir = (uchar8) (0, 0, 0, 0, 0, 0, 0, 0);
		dir = spixl_rep[idx];
		
		int bb_l = max((int)dir.s0, max((int)(dir.s1), (int)(dir.s2) ) );
		int bb_r = max((int)dir.s5, max((int)(dir.s6), (int)(dir.s7) ) );
		int bb_t = max((int)dir.s0, max((int)(dir.s3), (int)(dir.s5) ) );
		int bb_b = max((int)dir.s2, max((int)(dir.s4), (int)(dir.s7) ) );
		
		float2 step = (float2)(1, 1);
		step.x = fmax(1.0, 0.25*(float)(bb_l + bb_r) );
		step.y = fmax(1.0, 0.25*(float)(bb_t + bb_b) );
	///////////////////////////////////////////////////	
	
	
	float8 spixl = spixl_map[idx];
	float2 center = spixl.s12;
	int2 camIdx  = (int2)(z % array_width, z / array_width);
	float cost_est = 1000000.0, disp_est = 0.0;
	
	
	for (int dl = 0 ; dl < disp_num ; dl++)
	{
		float d = disp_level[dl];
		float min_val = 1000000.0;
		
		for (int n = 0 ; n < subset_num[z] ; n++)
		{
			
			int view = view_subset[view_count*z + n];
			
			int2 viewIdx = (int2)(view % array_width, view / array_width);
			float val = 0.0;
			
			for (int i = -2 ; i <= 2 ; i++) for (int j = -2 ; j <= 2 ; j++)
			{
				
				int2 xy_ref = (int2)(center.x + i*step.x, center.y + j*step.y);
				int2 xy_proj = (int2)((int)(xy_ref.x - d*(viewIdx.x - camIdx.x)), (int)(xy_ref.y - bl_ratio*d*(viewIdx.y - camIdx.y) ) );					
				//barrier(CLK_GLOBAL_MEM_FENCE);
				
				val += 30;
			
				if (xy_ref.x >= 0 && xy_ref.y >= 0 && xy_proj.x >= 0 && xy_proj.y >= 0 && xy_ref.x < img_size.x && xy_ref.y < img_size.y && xy_proj.x < img_size.x  && xy_proj.y < img_size.y)
				{
					/**/
					val -= 30;
					
					//barrier(CLK_GLOBAL_MEM_FENCE);
					float3 color_ref  = cvt_img[img_size.x*img_size.y*z + img_size.x*xy_ref.y  + xy_ref.x];		
					float3 color_proj = cvt_img[img_size.x*img_size.y*view  + img_size.x*xy_proj.y + xy_proj.x];
					val += fabs(color_ref.x - color_proj.x) + fabs(color_ref.y - color_proj.y) + fabs(color_ref.z - color_proj.z);
					
					//barrier(CLK_GLOBAL_MEM_FENCE);
					/**/	
				}
				//barrier(CLK_GLOBAL_MEM_FENCE);
				
			
			}
			if (val < min_val)
				min_val = val;
			//barrier(CLK_GLOBAL_MEM_FENCE);
		
		}
		
		if (min_val < cost_est)
		{
			cost_est = min_val;
			disp_est = d;
		}
		//barrier(CLK_GLOBAL_MEM_FENCE);	
	}
	
	//barrier(CLK_GLOBAL_MEM_FENCE);
	spixl_map[idx].s7 = disp_est;
	
}



kernel void compute_flatness(
global float8 *spixl_map,
global float2 *flatness_map,
int2 map_size, float gamma
)
{
	
	int x = get_global_id(0);
	int y = get_global_id(1);
	int z = get_global_id(2);
	
	if (x > map_size.x - 1 || y > map_size.y - 1)
		return;
	
	int idx = z*map_size.x*map_size.y + y*map_size.x + x;
	
	float3 c1;
	float3 c0;
	
	c0.x = spixl_map[idx].s3;
	c0.y = spixl_map[idx].s4;
	c0.z = spixl_map[idx].s5;
	
	float diff;
	float fl = 1.0;
	
	if (x - 1 > 0)
	{
		c1.x = spixl_map[idx - 1].s3;
		c1.y = spixl_map[idx - 1].s4;
		c1.z = spixl_map[idx - 1].s5;
		diff = (c1.x - c0.x)*(c1.x - c0.x) + (c1.y - c0.y)*(c1.y - c0.y) + (c1.z - c0.z)*(c1.z - c0.z);
		fl += diff;
	}
	
	if (x + 1 < map_size.x)
	{
		c1.x = spixl_map[idx + 1].s3;
		c1.y = spixl_map[idx + 1].s4;
		c1.z = spixl_map[idx + 1].s5;
		diff = (c1.x - c0.x)*(c1.x - c0.x) + (c1.y - c0.y)*(c1.y - c0.y) + (c1.z - c0.z)*(c1.z - c0.z);
		fl += diff;
	}
	
	if (y - 1 > 0)
	{
		c1.x = spixl_map[idx - map_size.x].s3;
		c1.y = spixl_map[idx - map_size.x].s4;
		c1.z = spixl_map[idx - map_size.x].s5;
		diff = (c1.x - c0.x)*(c1.x - c0.x) + (c1.y - c0.y)*(c1.y - c0.y) + (c1.z - c0.z)*(c1.z - c0.z);
		fl += diff;
	}
	
	if (y + 1 < map_size.y)
	{
		c1.x = spixl_map[idx + map_size.x].s3;
		c1.y = spixl_map[idx + map_size.x].s4;
		c1.z = spixl_map[idx + map_size.x].s5;
		diff = (c1.x - c0.x)*(c1.x - c0.x) + (c1.y - c0.y)*(c1.y - c0.y) + (c1.z - c0.z)*(c1.z - c0.z);
		fl += diff;
	}
	
	flatness_map[idx].s0 = exp(-fl*gamma);
	flatness_map[idx].s1 = 1 - exp(-0.25*fl*gamma);
}



float init_smoothness(global float8 *spixl_map, float8 sp_ref, float2 fl, int2 map_size, int3 pos, float gamma, float alpha, int no_kernel_steps, float kernel_step_size)
{
	float smoothness = 0.0;
	float weight_norm = 0.0;
	
	float3 color = (float3)(sp_ref.s3, sp_ref.s4, sp_ref.s5);
	float disp = sp_ref.s7;

	for (int i = -1 ; i <= 1 ; i++) for (int j = -1 ; j <= 1 ; j++)
	{
		int3 pos_check = (int3)(pos.x + i, pos.y + j, pos.z);
		
		if (pos_check.x >= 0 && pos_check.y >= 0 && pos_check.x < map_size.x && pos_check.y < map_size.y && (i != 0 || j != 0))
		{
			
			float diff, similarity;

			float8 sp_check = spixl_map[map_size.x*map_size.y*pos_check.z + map_size.x*pos_check.y + pos_check.x];
			float3 color_check = (float3)(sp_check.s3, sp_check.s4, sp_check.s5);
			float disp_check = sp_check.s7;
			
			diff = distance(color_check, color);
			similarity = exp(-diff*diff*gamma);
			
			diff = disp - disp_check;
			smoothness  += similarity * exp(-diff*diff*alpha);
			weight_norm += similarity;
			
		}
	}
	
	
	int step_size = max(1, (int)(fl.x*kernel_step_size + 0.5) );
	
	for (int i = 1 ; i <= no_kernel_steps ; i++)
	{
		float gamma_i = gamma*(1+i);
		int step = i*step_size;
		
		if (pos.x > step)// Left
		{
			
			float diff, similarity;
			
			float8 sp_check = spixl_map[map_size.x*map_size.y*pos.z + map_size.x*pos.y + pos.x - (step + 1)];
			float3 color_check = sp_check.s345;
			float disp_check = sp_check.s7;
			
			diff = distance(color, color_check);
			similarity = exp(-diff*diff*gamma_i);
			diff = disp - disp_check;
			
			smoothness  += similarity*exp(-diff*diff*alpha);
			weight_norm += similarity;
			
		}
		
		if (pos.x < map_size.x - step - 1)// Right
		{	
			float diff, similarity;
			
			float8 sp_check   = spixl_map[map_size.x*map_size.y*pos.z + map_size.x*pos.y + pos.x + (step + 1)];
			float3 color_check = sp_check.s345;
			float disp_check  = sp_check.s7;
			
			diff = distance(color, color_check);
			similarity = exp(-diff*diff*gamma_i);
			diff = disp - disp_check;
			
			smoothness  += similarity*exp(-diff*diff*alpha);
			weight_norm += similarity;
			
		}
		
		if (pos.y > step) // UP
		{
			
			float diff, similarity;
			
			float8 sp_check   = spixl_map[map_size.x*map_size.y*pos.z + map_size.x*(pos.y - step - 1) + pos.x];
			float3 color_check = sp_check.s345;
			float disp_check  = sp_check.s7;
			
			diff = distance(color, color_check);
			similarity = exp(-diff*diff*gamma_i);
			diff = disp - disp_check;
			
			smoothness  += similarity*exp(-diff*diff*alpha);
			weight_norm += similarity;
			
		}
		
		if (pos.y < map_size.y - step - 1) // Down
		{
			
			float diff, similarity;
			
			float8 sp_check    = spixl_map[map_size.x*map_size.y*pos.z + map_size.x*(pos.y + step + 1) + pos.x];
			float3 color_check = sp_check.s345;
			float disp_check   = sp_check.s7;
			
			diff = distance(color, color_check);
			similarity = exp(-diff*diff*gamma_i);
			diff = disp - disp_check;
			
			smoothness  += similarity*exp(-diff*diff*alpha);
			weight_norm += similarity;
			
		}
	}
	
	if (weight_norm > 0)
		return smoothness / weight_norm;
	else 
		return 0.000001;
	
}





float initialize_consistency(global float8 *spixl_map, global uint *idx_img, global uchar8 *spixl_rep, global int *view_subset, global int *subset_num, int3 pos, int array_width,
int2 map_size, int no_views, float3 color, float2 center, float d, float bl_ratio, int2 img_size, float fuse, float alpha, float gamma, float2 fl)
{
	
	float consistency = 0.0;
	int view_counter = 0;
	int2 camIdx;
	camIdx.x = pos.z % array_width;
	camIdx.y = pos.z / array_width;

	// Super pixels Samples
	uchar8 rep = spixl_rep[pos.z*map_size.x*map_size.y + pos.y*map_size.x + pos.x];

	int sp_samples[9];
	sp_samples[0] = (int)rep.s0;
	sp_samples[1] = (int)rep.s1;
	sp_samples[2] = (int)rep.s2;
	sp_samples[3] = (int)rep.s3;
	sp_samples[4] = 0;
	sp_samples[5] = (int)rep.s4;
	sp_samples[6] = (int)rep.s5;
	sp_samples[7] = (int)rep.s6;
	sp_samples[8] = (int)rep.s7;
	
	
	// Main For Loop
	for (int n = 0 ; n < subset_num[pos.z] ; n++)
	{
		
		int view = view_subset[pos.z * no_views + n];

		int2 viewIdx;
		viewIdx.x = view % array_width;
		viewIdx.y = view / array_width;

		// Consistency Variables
		float visib_weight_sum = 0.0f;
		float occl_weight_sum = 0.0;
		float num = 0.0;
		float visibility = 0.0;
		float visible = 0.0;


		for (int i = -1 ; i <= 1 ; i++) for (int j = -1 ; j <= 1 ; j++)
		{
			int2 xy_ref;
			xy_ref.x = (int)center.x + sp_samples[(i + 1) * 3 + j + 1] * i;
			xy_ref.y = (int)center.y + sp_samples[(i + 1) * 3 + j + 1] * j;

			int2 xy_proj;
			xy_proj.x = xy_ref.x - round(d*(viewIdx.x - camIdx.x));
			xy_proj.y = xy_ref.y - round(bl_ratio*d*(viewIdx.y - camIdx.y));

			if (xy_proj.x >= 0 && xy_proj.y >= 0 && xy_proj.x < img_size.x  && xy_proj.y < img_size.y)
			{
				uint idx_proj = idx_img[img_size.x*img_size.y*view + img_size.x*xy_proj.y + xy_proj.x];
				int2 coord_proj;
				coord_proj.x = idx_proj % map_size.x;
				coord_proj.y = idx_proj / map_size.x;
				float8 sp_proj = spixl_map[map_size.x*map_size.y*view + map_size.x*coord_proj.y + coord_proj.x];

				float diff = sp_proj.s7 - d;
				float when_visible = 0.0;
				if (diff < fuse)  when_visible = 1.0;
				visible += when_visible*exp(-diff*diff*alpha);
				visib_weight_sum += when_visible;
				occl_weight_sum += (1 - when_visible);

				float3 color_proj; 
				color_proj.x = sp_proj.s3; 
				color_proj.y = sp_proj.s4;
				color_proj.z = sp_proj.s5;
				diff = sqrt(pow(color_proj.x - color.x, 2) + pow(color_proj.y - color.y, 2) + pow(color_proj.z - color.z, 2) );
				visibility += exp(-diff * diff * gamma);

				num += 1;
			}
		}

		if (num > 0)
		{
			view_counter++;
			if (visib_weight_sum > 0)
				consistency += (visib_weight_sum / num)*(visibility / visib_weight_sum)*(visible / visib_weight_sum);

			if (occl_weight_sum > 0)
				consistency += 0.5*fl.y;
		}
		
	}
	
	if (view_counter > 0)
		return consistency / view_counter;
	else 
		return 0.01;
	
	
}







kernel void init_current_state(
global float8 *spixl_map,
global uint *idx_img,
global uchar8 *spixl_rep,
global float2 *flatness_map,
global float *current_state,
float gamma, float alpha, 
int no_kernel_steps, float kernel_step_size, 
float bl_ratio, float fuse, int2 map_size,
global int *view_subset,
global int *subset_num,
int array_width, int2 img_size, int no_views)
{
	
	int x = get_global_id(0);
	int y = get_global_id(1);
	int z = get_global_id(2);
	
	if (x >= map_size.x || y >= map_size.y)
			return;
	
	int idx = (map_size.x * map_size.y * z) + (map_size.x * y) + x;
	int idx_start = (6 * map_size.x * map_size.y * z) + (6 * map_size.x * y) + 6*x;
	
	
	int3 pos  = (int3)(x, y, z);
	float2 fl = flatness_map[idx];
	
	float8 current_spixl = spixl_map[idx];
	float3 color = current_spixl.s345;
	float2 center = current_spixl.s12;
	float d  = current_spixl.s7;
	
	float sm = init_smoothness(spixl_map, current_spixl, fl, map_size, pos, gamma, alpha, no_kernel_steps, kernel_step_size);
	float cs = initialize_consistency(spixl_map, idx_img, spixl_rep, view_subset, subset_num, pos, array_width, map_size, no_views, 
																											color,  center, d, bl_ratio, img_size, fuse, alpha, gamma, fl);
	
	current_state[idx_start + 0] = d;
	current_state[idx_start + 1] = sm;
	current_state[idx_start + 2] = cs;
	current_state[idx_start + 3] = 0.0;
	current_state[idx_start + 4] = 0.0;
	current_state[idx_start + 5] = 1.0;
	
		
}


float compute_smoothness(global float *current_state, global float8 *spixl_map, float d, float3 n, float2 center, float3 color, int x, int y, int z, float2 fl, int2 map_size, float gamma,
float alpha, int no_kernel_steps, float kernel_step_size)
{
	float smoothness = 0.0;
	float weight_norm = 0.0;
	

	for (int i = -1 ; i <= 1 ; i++) for (int j = -1 ; j <= 1 ; j++)
	{
		int3 pos_check = (int3)(x + i, y + j, z);
		
		if (pos_check.x >= 0 && pos_check.y >= 0 && pos_check.x < map_size.x && pos_check.y < map_size.y && (i != 0 || j != 0))
		{
			float diff, similarity;

			float8 sp_check = spixl_map[map_size.x * map_size.y * pos_check.z + map_size.x * pos_check.y + pos_check.x];
			float3 color_check = (float3)(sp_check.s3, sp_check.s4, sp_check.s5);
			float2 center_check = (float2)(sp_check.s1, sp_check.s2);
			
			diff = distance(color_check, color);
			similarity = exp(-diff * diff * gamma);
			
			float d_extp = (n.x * (center.x - sp_check.s1) + n.y * (center.y - sp_check.s2) + n.z * d) / n.z;
			
			
			diff = d_extp - current_state[(6 * map_size.x * map_size.y * z) + (6 * map_size.x * y) + 6 * x];
			smoothness  += similarity * exp(-diff * diff * alpha);
			weight_norm += similarity;
		}
	}
	
	
	int step_size = max(1, (int)(fl.x * kernel_step_size + 0.5) );
	
	for (int i = 1 ; i <= no_kernel_steps ; i++)
	{
		float gamma_i = gamma * (1+i);
		int step = i * step_size;
		
		
		if (x > step) // Left
		{
			int2 pos_check = (int2)(x - (step + 1), y);
			float diff, similarity;
		
			float8 sp_check = spixl_map[map_size.x * map_size.y * z + map_size.x * pos_check.y + pos_check.x];
			float2 center_check = (float2)(sp_check.s1, sp_check.s2);
			float3 color_check  = (float3)(sp_check.s3, sp_check.s4, sp_check.s5);

			diff = distance(color_check, color);
			similarity = exp(-diff * diff * gamma_i);

			float d_extp = (n.x * (center.x - sp_check.s1) + n.y * (center.y - sp_check.s2) + n.z * d) / n.z;

			diff = d_extp - current_state[(6 * map_size.x * map_size.y * z) + (6 * map_size.x * pos_check.y) + 6 * pos_check.x];
			smoothness += similarity * exp(-diff * diff * alpha);
			weight_norm += similarity;
		}
		
		if (x < map_size.x - step - 1) // Left
		{
			int2 pos_check = (int2)(x + (step + 1), y);
			float diff, similarity;
		
			float8 sp_check = spixl_map[map_size.x * map_size.y * z + map_size.x * pos_check.y + pos_check.x];
			float2 center_check = (float2)(sp_check.s1, sp_check.s2);
			float3 color_check  = (float3)(sp_check.s3, sp_check.s4, sp_check.s5);

			diff = distance(color_check, color);
			similarity = exp(-diff * diff * gamma_i);

			float d_extp = (n.x * (center.x - sp_check.s1) + n.y * (center.y - sp_check.s2) + n.z * d) / n.z;

			diff = d_extp - current_state[(6 * map_size.x * map_size.y * z) + (6 * map_size.x * pos_check.y) + 6 * pos_check.x];
			smoothness += similarity * exp(-diff * diff * alpha);
			weight_norm += similarity;
		}
		
		
	}
	
	
	if (weight_norm > 0)
		return smoothness / weight_norm;
	else 
		return 0.000001;
	
}



float compute_consistency(global float *current_state, global float8 *spixl_map, global uint *idx_img, uchar8 sp_rep, global int *view_subset, global int *subset_num, float d, 
float3 n, float2 center, float3 color, int x, int y, int z, float alpha, float gamma, float bl_ratio, float fuse, float2 fl, int array_width, int2 map_size, int2 img_size)
{
	
	// Set Parameters
	float consistency = 0;
	int view_counter = 0;
	int no_views = get_global_size(2);
	
	int2 camIdx;
	camIdx.x = z % array_width;
	camIdx.y = z / array_width;
	
	// Super pixels Samples
	int sp_samples[9];
	sp_samples[0] = (int)sp_rep.s0;
	sp_samples[1] = (int)sp_rep.s1;
	sp_samples[2] = (int)sp_rep.s2;
	sp_samples[3] = (int)sp_rep.s3;
	sp_samples[4] = 0;
	sp_samples[5] = (int)sp_rep.s4;
	sp_samples[6] = (int)sp_rep.s5;
	sp_samples[7] = (int)sp_rep.s6;
	sp_samples[8] = (int)sp_rep.s7;
	
	for (int k = 0 ; k < subset_num[z] ; k++)
	{
		int view = view_subset[no_views * z + k];

		int2 viewIdx;
		viewIdx.x = view % array_width;
		viewIdx.y = view / array_width;

		// Consistency Variables
		float visib_weight_sum = 0.0f;
		float occl_weight_sum = 0.0;
		float num = 0.0;
		float visibility = 0.0;
		float visible = 0.0;
		
		for (int i = -1 ; i <= 1 ; i++) for (int j = -1 ; j <= 1 ; j++)
		{ 
			// Take One Sample Point at a Time
			int2 xy;
			xy.x = (int)center.x + sp_samples[(i + 1) * 3 + j + 1] * i;
			xy.y = (int)center.y + sp_samples[(i + 1) * 3 + j + 1] * j;
			
			// Plane Interpolation
			float d_intrp = (n.x * (center.x - xy.x) + n.y * (center.y - xy.y) + n.z * d) / n.z;
			
			// Project the sample point in the Current Subset View
			int2 xy_proj;
			xy_proj.x = xy.x - round(d_intrp * (viewIdx.x - camIdx.x) );
			xy_proj.y = xy.y - round(bl_ratio * d_intrp * (viewIdx.y - camIdx.y) );
			
			if (xy_proj.x >= 0 && xy_proj.y >= 0 && xy_proj.x < img_size.x  && xy_proj.y < img_size.y)
			{
				uint idx_proj = idx_img[img_size.x * img_size.y * view + img_size.x * xy_proj.y + xy_proj.x];
				int2 coord_proj;
				coord_proj.x = idx_proj % map_size.x;
				coord_proj.y = idx_proj / map_size.x;
				
				// Load Proj Superpixel Info
				float8 sp_proj = spixl_map[map_size.x*map_size.y*view + map_size.x*coord_proj.y + coord_proj.x];
				float2 center_proj = (float2)(sp_proj.s1, sp_proj.s2);
				float3 color_proj = (float3)(sp_proj.s3, sp_proj.s4, sp_proj.s5);
				
				// Load Proj Superpixl State
				int state_idx = (6 * map_size.x * map_size.y * z) + (6 * map_size.x * coord_proj.y) + (6 * coord_proj.x);
				float d_proj = current_state[state_idx];
				float3 n_proj = (float3)(current_state[state_idx + 3], current_state[state_idx + 4], current_state[state_idx + 5]);
				
				// Interpolate Proj SP in the Plane Equ
				float d_intrp_proj = (n_proj.x * (center_proj.x - xy_proj.x) + n_proj.y * (center_proj.y - xy_proj.y) + n_proj.z * d_proj) / n_proj.z;
				
				//
				float diff = d_intrp_proj - d;
				float when_visible = 0.0;
				if (diff < fuse)  when_visible = 1.0;
				visible += when_visible * exp(-diff*diff*alpha);
				visib_weight_sum += when_visible;
				occl_weight_sum += (1 - when_visible);

				diff = distance(color_proj, color);
				visibility += exp(-diff * diff * gamma);

				num += 1;

			}
			
		}
		
		if (num > 0)
		{
			view_counter++;
			if (visib_weight_sum > 0)
				consistency += (visib_weight_sum / num) * (visibility / visib_weight_sum) * (visible / visib_weight_sum);

			if (occl_weight_sum > 0)
				consistency += 0.5 * fl.y;
		}	
	}
	
	
	if (view_counter > 0)
		return consistency / view_counter;
	else 
		return 0.01;
	
}

/**/


float8 update(global float *current_state, global float8 *spixl_map, global uint *idx_img, uchar8 sp_rep, global int *view_subset, global int *subset_num, 
int iter, int2 map_size, int2 img_size, float alpha, float gamma, float bl_ratio, float fuse, int no_kernel_steps, float kernel_step_size, int array_width, int x, int y, int z, float3 color,
float2 center, float sm0, float cs0, float3 n0, float d0, int idx_check, int idx_state_check, float2 fl)
{
	float3 n1 = (float3)(current_state[idx_state_check + 3], current_state[idx_state_check + 4], current_state[idx_state_check + 5]);
	float d1 = current_state[idx_state_check];
	
	
	// Load Neighbor Sp Info
	float8 sp_check = spixl_map[idx_check];
	float3 color_check = (float3)(sp_check.s3, sp_check.s4, sp_check.s5);
	float2 center_check = (float2)(sp_check.s1, sp_check.s2);
	
	// Interpolate	
	float d_intrp = (n1.x*(center_check.x - center.x) + n1.y*(center_check.y - center.y) + n1.z*d1) / n1.z;
	
	// New Smoothness and Consistency with Neighboring Plane Parameters (n1, d_intrp)
	float sm1 = compute_smoothness(current_state, spixl_map, d_intrp, n1, center, color, x, y, z, fl, map_size, gamma, alpha, no_kernel_steps, kernel_step_size);
	float cs1 = compute_consistency(current_state, spixl_map, idx_img, sp_rep, view_subset, subset_num, d_intrp, n1, center, color, x, y, z, alpha, 
																																gamma, bl_ratio, fuse, fl, array_width, map_size, img_size);
	
	// Update
	float diff = distance(color, color_check);
	float similarity = exp(-diff * diff * gamma);
	
	float sm_update = sm0, cs_update = cs0, d_update = d0;
	float3 n_update = n0;
	
	//if ((iter < 4 && sm1 * similarity > sm0) || cs1 * sm1 > sm0 * cs0)
	//{
		d_update = d_intrp;
		sm_update = sm1;
		cs_update = cs1;
		n_update = n1;
	//}

	float8 update_state = (float8)(d_update, sm_update, cs_update, n_update.x, n_update.y, n_update.z, 0, 0);
	return update_state;
}

/**/


kernel void propagate(global float *current_state_update, global float *current_state, global float8 *spixl_map, global uint *idx_img, global uchar8 *spixl_rep, global float2 *flatness_map,
global int *view_subset, global int *subset_num, int iter, int2 map_size, int2 img_size, float alpha, float gamma, float bl_ratio, float fuse, int no_kernel_steps, float kernel_step_size, 
int array_width, int flag_norm)
{
	int x = get_global_id(0);
	int y = get_global_id(1);
	int z = get_global_id(2);
	
	if (x >= map_size.x || y >= map_size.y)
		return;
	
	int state_idx = (6 * map_size.x * map_size.y * z) + (6 * map_size.x * y) + (6 * x);
	
	int idx = map_size.x * map_size.y * z + map_size.x * y + x;

	// Load Sp Info
	float8 sp = spixl_map[idx];
	float2 center; center.x = sp.s1; center.y = sp.s2;
	float3 color; color.x = sp.s3; color.y = sp.s4; color.z = sp.s5;
	
	
	// Load Sp State
	float d0  = current_state[state_idx];
	float sm0 = current_state[state_idx + 1];
	float cs0 = current_state[state_idx + 2];
	
	// Normal Vector
	float3 n0;
	n0.x = current_state[state_idx + 3];
	n0.y = current_state[state_idx + 4];
	n0.z = current_state[state_idx + 5];
	
	// Load Inputs
	float2 fl = flatness_map[idx];
	uchar8 sp_rep = spixl_rep[idx];
	
	
	
	// Propagate Info for Immidiate Neighbors
	
	for (int i = -1; i <= 1; i++) for (int j = -1; j <= 1; j++)
	{
		int3 p = (int3)(x + i, y + j, z);
		
		if (p.x >= 0 && p.y >= 0 && p.x < map_size.x && p.y < map_size.y && !(i == 0 && j == 0))
		{
			int state_idx_nbr = (6 * map_size.x * map_size.y * p.z) + (6 * map_size.x * p.y) + (6 * p.x);

			int idx_check = (map_size.x * map_size.y * p.z) + (map_size.x * p.y) + p.x;

			// Update the Plane		
			/**/
			float8 updated_surface = update(current_state, spixl_map, idx_img, sp_rep, view_subset, subset_num, iter, map_size, img_size, alpha, gamma, bl_ratio, fuse, 
																			no_kernel_steps,kernel_step_size, array_width, x, y, z, color, center, sm0, cs0, n0, d0, idx_check, state_idx_nbr, fl);
			
			d0  = updated_surface.s0;
			sm0 = updated_surface.s1;
			cs0 = updated_surface.s2;
			n0  = (float3)(updated_surface.s3, updated_surface.s4, updated_surface.s5);	
			/**/
		}	
	}
	
	
	current_state_update[state_idx + 0] = d0;
	current_state_update[state_idx + 1] = sm0;
	current_state_update[state_idx + 2] = cs0;

	current_state_update[state_idx + 3] = n0.x;
	current_state_update[state_idx + 4] = n0.y;
	current_state_update[state_idx + 5] = n0.z;
}	






















