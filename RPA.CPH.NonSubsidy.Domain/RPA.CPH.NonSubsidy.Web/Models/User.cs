namespace RPA.CPH.NonSubsidy.Web.Models
{
    public class User : IUser
    {
        private readonly IHttpContextAccessor httpContextAccessor;

        public User(IHttpContextAccessor httpContextAccessor)
        {
            this.httpContextAccessor = httpContextAccessor;
        }

        public string Name
        {
            get
            {
                return httpContextAccessor.HttpContext.User.Identity.Name.ToLower().Replace("earth\\", "").Replace("m0", "m");
            }
        }
    }
}
