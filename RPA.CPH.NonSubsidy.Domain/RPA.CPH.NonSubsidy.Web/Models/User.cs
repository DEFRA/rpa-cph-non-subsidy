using System;
using System.Collections.Generic;
using System.Linq;
using System.Web;

namespace RPA.CPH.NonSubsidy.Web.Models
{
    public class User : IUser
    {
        public string Name
        {
            get
            {
                return HttpContext.Current.User.Identity.Name.ToLower().Replace("earth\\", "").Replace("m0", "m");
            }
        }
    }
}